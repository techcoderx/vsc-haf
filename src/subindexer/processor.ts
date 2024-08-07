import logger from '../logger.js'
import db from '../db.js'
import { L2PayloadTypes, ParsedOp, VscOp, BlockOp, OpBody, BridgeRefPayload, CustomJsonPayloads, BridgeRefResult, ElectionOp, ElectionPayload2, ElectionMember, ElectionMemberWeighted, ShuffledSchedule, UnsignedBlock, BlockPayload, L1CallTxOp, L1TxPayload, NewContractPayload, NewContractOp } from '../processor_types.js'
import { BlockScheduleParams, LastElectionDetail, WitnessConsensusDid } from '../psql_types.js'
import { QueryResult } from 'pg'
import ipfs from './ipfs.js'
import { CID } from 'kubo-rpc-client'
import { bech32 } from 'bech32'
import { createDag, isCID, encodePayload } from './ipfs_dag.js'
import { BlsCircuit, initBls } from '../utils/bls-did.js'
import op_type_map from '../operations.js'
import { AnchorRefBody, AnchorRefHead, BlockBody, BridgeRef, ContractCallBody, ContractOutBody, ContractStorageProof, EventOutBody, InputBody, TransferBody } from './ipfs_payload.js'
import { APP_CONTEXT, CONTRACT_DATA_AVAILABLITY_PROOF_REQUIRED_HEIGHT, EPOCH_LENGTH, MIN_BLOCKS_SINCE_LAST_ELECTION, MAX_BLOCKS_SINCE_LAST_ELECTION, ROUND_LENGTH, SCHEMA_NAME, SUPERMAJORITY, ELECTION_UPDATE_1_EPOCH, ELECTION_UPDATE_2_EPOCH } from '../constants.js'
import { shuffle } from '../utils/shuffle-seed.js'
import BitSet from 'bitset'

await initBls()

const schedule: {
    shuffled?: ShuffledSchedule[] | null
    height?: number
    epoch?: number
} = {}

class Range {
    public start: number
    public end: number

    constructor(start: number, end: number) {
        if (end <= start) {
            throw new Error(`range error: end > start must be true {end: ${end}, start: ${start}}`)
        }
        this.start = start
        this.end = end
    }

    static from([start, end]: [number, number]) {
        return new Range(start, end);
    }

    position(value: number) {
        const {start, end} = this
        if (value < start || value > end) {
            throw new Error(`range error: value ${value} not in range [${start},${end}]`)
        }
        return (value - start) / (end - start)
    }

    value(position: number) {
        const {start, end} = this
        if (position < 0 || position > 1) {
            throw new Error(`range error: position ${position} not in range [0,1]`)
        }
        return position * (end - start) + start
    }

    map(value: number, to: Range) {
        const position = this.position(value)
        return to.value(position)
    }
}

const minimalRequiredElectionVotes = (blocksSinceLastElection: number, memberCountOfLastElection: number): number => {
    if (blocksSinceLastElection < MIN_BLOCKS_SINCE_LAST_ELECTION) {
        throw new Error('tried to run election before time slot')
    }
    const minMembers = Math.floor((memberCountOfLastElection / 2) + 1) // 1/2 + 1
    const maxMembers = Math.ceil(memberCountOfLastElection * 2 / 3) // 2/3
    const drift = (MAX_BLOCKS_SINCE_LAST_ELECTION - Math.min(blocksSinceLastElection, MAX_BLOCKS_SINCE_LAST_ELECTION)) / MAX_BLOCKS_SINCE_LAST_ELECTION;
    return Math.round(Range.from([0, 1]).map(drift, Range.from([minMembers, maxMembers])));
}

const verifyStorageProof = async (block_num: number, proofCID: CID, sig: string | Buffer, bv: string | Buffer): Promise<{isValid: boolean, circuit: BlsCircuit, bs: BitSet}> => {
    if (typeof sig === 'string')
        sig = Buffer.from(sig, 'base64url')
    if (typeof bv === 'string')
        bv = Buffer.from(bv, 'base64url')
    const members = await db.client.query<WitnessConsensusDid>(`SELECT * FROM ${SCHEMA_NAME}.get_members_at_block($1);`,[block_num])
    const keyset = members.rows.map(m => m.consensus_did)
    const {circuit, bs} = BlsCircuit.deserializeRaw({ hash: proofCID.bytes }, sig, bv, keyset)
    const isValid = await circuit.verify(proofCID.bytes)
    return {isValid, circuit, bs}
}

const processor = {
    validateAndParse: async (op: VscOp): Promise<ParsedOp<L2PayloadTypes>> => {
        // we know at this point that the operation looks valid as it has
        // been validated in main HAF app sync, however we perform further
        // validation and parsing on data only accessible in IPFS here.
        // most of the code for validation here are from vsc-node repo
        // these are all custom jsons, so we parse the json payload right away
        let parsed: OpBody = JSON.parse(op.body)
        let details: ParsedOp<L2PayloadTypes> = {
            valid: true,
            user: parsed.value.required_auths.length > 0 ? parsed.value.required_auths[0] : parsed.value.required_posting_auths[0],
            block_num: op.block_num,
            trx_in_block: op.trx_in_block,
            op_pos: op.op_pos
        }
        try {
            let payload: CustomJsonPayloads = JSON.parse(parsed.value.json)
            let sig: Buffer, bv: Buffer, merkle: Buffer //, members: QueryResult<WitnessConsensusDid>
            switch (op.op_type) {
                case op_type_map.map.propose_block:
                    // propose block
                    payload = payload as BlockOp
                    sig = Buffer.from(payload.signed_block.signature.sig, 'base64url')
                    bv = Buffer.from(payload.signed_block.signature.bv, 'base64url')
                    merkle = Buffer.from(payload.signed_block.merkle_root, 'base64url')
                    const witnessSet = await db.client.query<WitnessConsensusDid>(`SELECT * FROM ${SCHEMA_NAME}.get_members_at_block($1);`,[op.block_num])
                    const scheduleParams = (await db.client.query<BlockScheduleParams>(`SELECT * FROM ${SCHEMA_NAME}.get_block_schedule_params($1);`,[op.block_num])).rows[0]
                    if (!schedule.shuffled || schedule.height !== scheduleParams.past_rnd_height || schedule.epoch !== scheduleParams.epoch) {
                        const outSchedule: WitnessConsensusDid[] = []
                        for (let x = 0; x < scheduleParams.total_rnds; x++)
                            if (witnessSet.rows[x % witnessSet.rows.length])
                                outSchedule.push(witnessSet.rows[x % witnessSet.rows.length])
                        schedule.shuffled = shuffle(outSchedule, scheduleParams.block_id).map((e, index) => {
                            const idxRndLen = scheduleParams.past_rnd_height + (index * scheduleParams.rnd_length)
                            return {
                                ...e,
                                bn: idxRndLen,
                                bn_works: idxRndLen % scheduleParams.rnd_length === 0,
                                in_past: idxRndLen < op.block_num
                            }
                        })
                        schedule.height = scheduleParams.past_rnd_height
                        schedule.epoch = scheduleParams.epoch
                    }
                    const blockSlotHeight = op.block_num - (op.block_num % ROUND_LENGTH)
                    let witnessSlot = schedule.shuffled.find(e => e.bn === blockSlotHeight && e.name === details.user)
                    logger.trace('Witness slot at',op.id,witnessSlot)
                    // logger.trace('Witness in schedule:',schedule.shuffled.filter(e => e.name === details.user))
                    if (witnessSlot) {
                        const unsignedBlock: UnsignedBlock<CID> = {
                            ...payload.signed_block,
                            block: CID.parse(payload.signed_block.block)
                        }
                        delete unsignedBlock.signature
                        const {totalWeight, votedWeight, circuit, bs} = BlsCircuit.deserializeRaw(unsignedBlock, sig, bv, witnessSet.rows.map(m => m.consensus_did), witnessSet.rows.map(m => m.weight))
                        const isValid = await circuit.verify((await createDag(unsignedBlock)).bytes)
                        const blockCIDShort = `${payload.signed_block.block.substring(0,12)}...${payload.signed_block.block.slice(-6)}`
                        logger.debug(`Block ${blockCIDShort} by ${witnessSlot.name}: ${bs.toString(2)} ${isValid}`)
                        if (isValid && votedWeight/totalWeight >= SUPERMAJORITY) {
                            // vsc-node does not currently check previous block header when syncing
                            // if we do check here, as the testnet genesis block isn't valid (published way out of schedule)
                            // therefore every block thereafter would be invalid
                            details.payload = {
                                block_hash: payload.signed_block.block,
                                block_header_cid: (await createDag(unsignedBlock)).toString(),
                                br: payload.signed_block.headers.br,
                                merkle_root: merkle,
                                signature: { sig, bv },
                                txs: [],
                                voted_weight: votedWeight
                            } as BlockPayload
                            const blockTxs: BlockBody = (await ipfs.dag.get(CID.parse(payload.signed_block.block))).value
                            if (!Array.isArray(blockTxs.txs)) {
                                logger.warn(`Accepting BLS validated block ${blockCIDShort} with no txs due to invalid block body on IPFS`)
                                return details
                            }
                            for (let t in blockTxs.txs) {
                                if (typeof blockTxs.txs[t].id !== 'string' ||
                                    !isCID(blockTxs.txs[t].id) ||
                                    CID.parse(blockTxs.txs[t].id).code !== 0x71 ||
                                    typeof blockTxs.txs[t].type !== 'number' ||
                                    ![1,2,5,6].includes(blockTxs.txs[t].type)) {
                                    logger.warn(`Ignoring invalid tx at index ${t} in block ${blockCIDShort}`)
                                    continue
                                }
                                try {
                                    if (blockTxs.txs[t].type === 1) {
                                        const txBody: InputBody = (await ipfs.dag.get(CID.parse(blockTxs.txs[t].id))).value
                                        if (typeof txBody.headers !== 'object' ||
                                            typeof txBody.headers.nonce !== 'number' ||
                                            !Array.isArray(txBody.headers.required_auths) ||
                                            typeof txBody.tx !== 'object') {
                                            logger.warn(`Ignoring malformed input tx at index ${t} in block ${blockCIDShort}`)
                                            continue
                                        }
                                        if (txBody.tx.op === 'call_contract') {
                                            // contract call
                                            if (typeof txBody.tx.action !== 'string' ||
                                                typeof txBody.tx.contract_id !== 'string') {
                                                logger.warn(`Invalid action/contract_id at index ${t} in block ${blockCIDShort}`)
                                                continue
                                            }
                                            const contractExists = await db.client.query(`SELECT * FROM ${SCHEMA_NAME}.contracts WHERE contract_id=$1;`,[txBody.tx.contract_id])
                                            if (contractExists.rowCount! === 0) {
                                                logger.warn(`Ignoring contract call to non-existent contract at index ${t} in block ${blockCIDShort}`)
                                                continue
                                            }
                                            let invalidAuths = false
                                            for (let i in txBody.headers.required_auths)
                                                if (typeof txBody.headers.required_auths[i] !== 'string' ||
                                                    txBody.headers.required_auths[i].length > 78 ||
                                                    !txBody.headers.required_auths[i].startsWith('did:')) {
                                                    logger.warn(`Ignoring tx with invalid auth at index ${t} in block ${blockCIDShort}`)
                                                    invalidAuths = true
                                                    break
                                                }
                                            if (invalidAuths)
                                                continue
                                            details.payload.txs.push({
                                                id: blockTxs.txs[t].id,
                                                type: 1,
                                                op: 'call_contract',
                                                index: parseInt(t),
                                                contract_id: txBody.tx.contract_id,
                                                action: txBody.tx.action,
                                                payload: [txBody.tx.payload],
                                                callers: txBody.headers.required_auths,
                                                nonce: txBody.headers.nonce
                                            })
                                        } else if (txBody.tx.op === 'transfer') {
                                            if (typeof txBody.tx.payload !== 'object' ||
                                                typeof txBody.tx.payload.amount !== 'number' ||
                                                txBody.tx.payload.amount < 0 ||
                                                typeof txBody.tx.payload.from !== 'string' ||
                                                typeof txBody.tx.payload.to !== 'string' ||
                                                (txBody.tx.payload.tk !== 'HIVE' && txBody.tx.payload.tk !== 'HBD')
                                            )
                                                return { valid: false }
                                            details.payload.txs.push({
                                                id: blockTxs.txs[t].id,
                                                type: 1,
                                                op: 'transfer',
                                                index: parseInt(t),
                                                amount: txBody.tx.payload.amount,
                                                from: txBody.tx.payload.from,
                                                to: txBody.tx.payload.to,
                                                tk: txBody.tx.payload.tk,
                                                memo: txBody.tx.payload.memo
                                            })
                                        } else if (txBody.tx.op === 'withdraw') {
                                            if (typeof txBody.tx.payload !== 'object' ||
                                                typeof txBody.tx.payload.amount !== 'number' ||
                                                txBody.tx.payload.amount < 0 ||
                                                typeof txBody.tx.payload.from !== 'string' ||
                                                typeof txBody.tx.payload.to !== 'string' ||
                                                (txBody.tx.payload.tk !== 'HIVE' && txBody.tx.payload.tk !== 'HBD')
                                            )
                                                return { valid: false }
                                            details.payload.txs.push({
                                                id: blockTxs.txs[t].id,
                                                type: 1,
                                                op: 'withdraw',
                                                index: parseInt(t),
                                                amount: txBody.tx.payload.amount,
                                                from: txBody.tx.payload.from,
                                                to: txBody.tx.payload.to,
                                                tk: txBody.tx.payload.tk,
                                                memo: txBody.tx.payload.memo
                                            })
                                        }
                                    } else if (blockTxs.txs[t].type === 2) {
                                        const txBody: ContractOutBody = (await ipfs.dag.get(CID.parse(blockTxs.txs[t].id))).value
                                        // contract output
                                        if (typeof txBody.contract_id !== 'string' ||
                                            !Array.isArray(txBody.inputs) ||
                                            (typeof txBody.io_gas !== 'number' && txBody.io_gas !== null) ||
                                            !Array.isArray(txBody.results)) {
                                            logger.warn(`Ignoring contract output with malformed data at index ${t} in block ${blockCIDShort}`)
                                            continue
                                        }
                                        const contractExists = await db.client.query(`SELECT * FROM ${SCHEMA_NAME}.contracts WHERE contract_id=$1;`,[txBody.contract_id])
                                        if (contractExists.rowCount! === 0) {
                                            logger.warn(`Ignoring contract output for non-existent contract at index ${t} in block ${blockCIDShort}`)
                                            continue
                                        }
                                        let invalidInputs = false
                                        for (let i in txBody.inputs)
                                            if (typeof txBody.inputs[i] !== 'string' || !txBody.inputs[i] || txBody.inputs[i].length > 59) {
                                                logger.warn(`Ignoring contract output due to invalid input, tx index ${t} in block ${blockCIDShort}`)
                                                invalidInputs = true
                                                break
                                            }
                                        if (invalidInputs)
                                            continue
                                        if (txBody.inputs.length !== txBody.results.length) {
                                            logger.warn(`Ignoring contract output due to non-equal array length of inputs and results, index ${t} in block ${blockCIDShort}`)
                                            continue
                                        }
                                        details.payload.txs.push({
                                            id: blockTxs.txs[t].id,
                                            type: 2,
                                            index: parseInt(t),
                                            contract_id: txBody.contract_id,
                                            inputs: txBody.inputs,
                                            io_gas: txBody.io_gas,
                                            results: txBody.results
                                        })
                                    } else if (blockTxs.txs[t].type === 5) {
                                        const txBody: AnchorRefBody = (await ipfs.dag.get(CID.parse(blockTxs.txs[t].id))).value
                                        const arh = blockTxs.txs[t] as AnchorRefHead
                                        const txroot = Buffer.from(arh.data, 'base64url')
                                        if (txroot.length !== 32 || !Array.isArray(txBody.txs) || arh.chain !== 'hive') {
                                            logger.warn(`Ignoring invalid anchor ref tx in block ${blockCIDShort}`)
                                            continue
                                        }
                                        let invalidRefs = false
                                        for (let b in txBody.txs)
                                            if (!(txBody.txs[b] instanceof Uint8Array) || txBody.txs[b].length !== 20) {
                                                logger.warn(`Ignoring invalid anchor ref in block ${blockCIDShort}`)
                                                invalidRefs = true
                                                break
                                            }
                                        if (invalidRefs)
                                            continue
                                        details.payload.txs.push({
                                            id: blockTxs.txs[t].id,
                                            type: 5,
                                            index: parseInt(t),
                                            chain: 'hive',
                                            data: txroot.toString('hex'),
                                            txs: txBody.txs.map(b => Buffer.from(b).toString('hex')) // buffer cannot be serialized into json
                                        })
                                    } else if (blockTxs.txs[t].type === 6) {
                                        const eventBody: EventOutBody = (await ipfs.dag.get(CID.parse(blockTxs.txs[t].id))).value
                                        // for events we let pgsql to handle validation
                                        details.payload.txs.push({
                                            id: blockTxs.txs[t].id,
                                            type: 6,
                                            index: parseInt(t),
                                            body: eventBody
                                        })
                                    }
                                } catch (e) {
                                    logger.warn(`Ignoring tx that failed to parse at index ${t} in block ${blockCIDShort}`)
                                    logger.trace(e)
                                    continue
                                }
                            }
                        } else
                            return { valid: false }
                    } else
                        return { valid: false }
                    break
                case op_type_map.map.create_contract:
                    payload = payload as NewContractOp
                    const trx_hash = await db.client.query(`SELECT ${SCHEMA_NAME}.get_tx_hash_by_op($1,$2::SMALLINT);`,[details.block_num,details.trx_in_block])
                    const contractIdHash = (await encodePayload({
                        ref_id: trx_hash.rows[0].get_tx_hash_by_op,
                        index: details.op_pos!.toString()
                    })).cid
                    const bech32Addr = bech32.encode('vs4', bech32.toWords(contractIdHash.bytes))
                    details.payload = {
                        contract_id: bech32Addr,
                        code: payload.code
                    }
                    if (typeof payload.name === 'string')
                        details.payload.name = payload.name
                    if (typeof payload.description === 'string')
                        details.payload.description = payload.description
                    if (op.block_num >= CONTRACT_DATA_AVAILABLITY_PROOF_REQUIRED_HEIGHT) {
                        const proofCID = CID.parse(payload.storage_proof!.hash)
                        const proof: ContractStorageProof = (await ipfs.dag.get(proofCID)).value
                        if (proof.cid !== payload.code || proof.type !== 'data-availability')
                            return { valid: false }
                        sig = Buffer.from(payload.storage_proof!.signature.sig, 'base64url')
                        bv = Buffer.from(payload.storage_proof!.signature.bv, 'base64url')
                        const { isValid, bs } = await verifyStorageProof(op.block_num, proofCID, sig, bv)
                        logger.debug(`New contract at op ${op.id} storage proof: ${bs.toString(2)} ${isValid}`)
                        if (!isValid)
                            return { valid: false }
                        details.payload.storage_proof = {
                            hash: payload.storage_proof!.hash,
                            signature: {
                                sig: sig,
                                bv: bv
                            }
                        }
                    }
                    break
                case op_type_map.map.update_contract:
                    payload = payload as NewContractOp
                    details.payload = {
                        contract_id: payload.id,
                        code: payload.code
                    }
                    const proofCID = CID.parse(payload.storage_proof!.hash)
                    const proof: ContractStorageProof = (await ipfs.dag.get(proofCID)).value
                    if (proof.cid !== payload.code || proof.type !== 'data-availability')
                        return { valid: false }
                    sig = Buffer.from(payload.storage_proof!.signature.sig, 'base64url')
                    bv = Buffer.from(payload.storage_proof!.signature.bv, 'base64url')
                    {
                    const { isValid, bs } = await verifyStorageProof(op.block_num, proofCID, sig, bv)
                    logger.debug(`Update contract at op ${op.id} storage proof: ${bs.toString(2)} ${isValid}`)
                    if (!isValid)
                        return { valid: false }
                    details.payload.storage_proof = {
                        hash: payload.storage_proof!.hash,
                        signature: {
                            sig: sig,
                            bv: bv
                        }
                    }
                    }
                    break
                case op_type_map.map.tx:
                    payload = payload as L1CallTxOp
                    const contractExists = await db.client.query(`SELECT * FROM ${SCHEMA_NAME}.contracts WHERE contract_id=$1;`,[payload.tx.contract_id])
                    if (contractExists.rowCount! === 0)
                        return { valid: false }
                    details.payload = {
                        callers: [],
                        contract_id: payload.tx.contract_id,
                        action: payload.tx.action,
                        payload: payload.tx.payload
                    } as L1TxPayload
                    for (let i in parsed.value.required_auths)
                        details.payload.callers.push({ user: parsed.value.required_auths[i], auth: 1 })
                    for (let i in parsed.value.required_posting_auths)
                        details.payload.callers.push({ user: parsed.value.required_posting_auths[i], auth: 2 })
                    break
                case op_type_map.map.election_result:
                    // election result
                    payload = payload as ElectionOp
                    sig = Buffer.from(payload.signature.sig, 'base64url')
                    bv = Buffer.from(payload.signature.bv, 'base64url')
                    const slotHeight = op.block_num - (op.block_num % EPOCH_LENGTH)
                    const members = await db.client.query<WitnessConsensusDid>(`SELECT * FROM ${SCHEMA_NAME}.get_members_at_block($1);`,[op.block_num])
                    const membersAtSlotStart = await db.client.query<WitnessConsensusDid>(`SELECT * FROM ${SCHEMA_NAME}.get_members_at_block($1);`,[slotHeight])
                    const lastElection = await db.client.query<LastElectionDetail>(`SELECT * FROM ${SCHEMA_NAME}.get_last_election_at_block($1);`,[op.block_num])
                    const keyWeights: {[key: string]: number} = {}
                    members.rows.forEach(m => keyWeights[m.consensus_did] = m.weight)
                    const d = {
                        data: payload.data,
                        epoch: payload.epoch,
                        net_id: payload.net_id
                    }
                    const nextEpoch = lastElection.rows.length > 0 ? lastElection.rows[0].epoch+1 : 0
                    {
                    const {pubKeys, circuit, bs} = BlsCircuit.deserializeRaw(d, sig, bv, membersAtSlotStart.rows.map(m => m.consensus_did))
                    const isValid = await circuit.verify((await createDag(d)).bytes)
                    logger.debug(`Epoch ${d.epoch} election: ${bs.toString(2)} ${isValid}`)
                    const votedWeight = pubKeys.reduce<number>((w: number, k) => w+(keyWeights[k] ?? 0), 0)
                    const voteMajority = (nextEpoch < ELECTION_UPDATE_1_EPOCH) ? members.rowCount! * SUPERMAJORITY : minimalRequiredElectionVotes(op.block_num - lastElection.rows[0].bh, lastElection.rows[0].total_weight)
                    if (isValid && ((votedWeight >= voteMajority) || payload.epoch === 0)) {
                        const electedMembers: { members: ElectionMember<string>[], weights?: number[], weight_total?: number } = (await ipfs.dag.get(CID.parse(payload.data))).value
                        if (!Array.isArray(electedMembers.members))
                            return { valid: false }
                        else if (nextEpoch >= ELECTION_UPDATE_2_EPOCH && (!Array.isArray(electedMembers.weights) || typeof electedMembers.weight_total !== 'number' || electedMembers.weights.length !== electedMembers.members.length)) {
                            logger.warn(`Ignoring un-weighted or invalid-weighted election post-update 2`)
                            return { valid: false }
                        }
                        const validatedElectedMembers: ElectionMemberWeighted<number>[] = []
                        for (let m in electedMembers.members) {
                            if (typeof electedMembers.members[m].account !== 'string' || typeof electedMembers.members[m].key !== 'string')
                                continue
                            const accountExists = await db.client.query(`SELECT * FROM hive.${APP_CONTEXT}_accounts WHERE name=$1;`,[electedMembers.members[m].account])
                            if (accountExists.rows.length === 0)
                                continue
                            validatedElectedMembers.push({
                                account: accountExists.rows[0].id as number,
                                key: electedMembers.members[m].key,
                                weight: electedMembers.weights ? electedMembers.weights[m] : 1
                            })
                        }
                        details.payload = {
                            ...d,
                            signature: { sig, bv },
                            members: validatedElectedMembers,
                            voted_weight: votedWeight,
                            weight_total: electedMembers.weight_total ?? electedMembers.members.length
                        } as ElectionPayload2
                    } else
                        return { valid: false }
                    }
                    break
                case op_type_map.map.bridge_ref:
                    // bridge ref
                    payload = payload as BridgeRefPayload
                    const bridgeRefContent: BridgeRef = (await ipfs.dag.get(CID.parse(payload.ref_id))).value
                    if (!Array.isArray(bridgeRefContent.withdrawals))
                        return { valid: false }
                    logger.trace('Bridge ref contents',bridgeRefContent)
                    const result = []
                    for (let w in bridgeRefContent.withdrawals) {
                        if (typeof bridgeRefContent.withdrawals[w].id !== 'string')
                            continue
                        const parts = bridgeRefContent.withdrawals[w].id.split('-')
                        if (parts.length !== 2 || !/^[0-9a-fA-F]{40}$/i.test(parts[0]))
                            continue
                        const opPos = parseInt(parts[1])
                        if (isNaN(opPos) || opPos < 0)
                            continue
                        const vscOpId = await db.client.query(`SELECT * FROM ${SCHEMA_NAME}.get_vsc_op_by_tx_hash($1,$2);`,[parts[0].toLowerCase(),opPos])
                        if (vscOpId.rowCount === 0 || vscOpId.rows[0].op_type !== 11)
                            continue
                        result.push(vscOpId.rows[0].id)
                    }
                    details.payload = result
                    break
                default:
                    break
            }
            return details
        } catch (e) {
            logger.debug('Failed to process operation, id:',op.id)
            logger.debug(e)
            return { valid: false }
        }
    },
    process: async (op: VscOp): Promise<boolean> => {
        let result = await processor.validateAndParse(op)
        if (result.valid) {
            logger.trace('Processing op',op.id,result)
            switch (op.op_type) {
                case op_type_map.map.propose_block:
                    result.payload = result.payload as BlockPayload
                    await db.client.query(`SELECT ${SCHEMA_NAME}.push_block($1,$2,$3,$4,$5,$6,$7,$8,$9,$10::jsonb,$11);`,[
                        op.id,
                        result.user,
                        result.payload.block_hash,
                        result.payload.block_header_cid,
                        result.payload.br[0],
                        result.payload.br[1],
                        result.payload.merkle_root,
                        result.payload.signature.sig,
                        result.payload.signature.bv,
                        JSON.stringify(result.payload.txs),
                        result.payload.voted_weight
                    ])
                    break
                case op_type_map.map.create_contract:
                    result.payload = result.payload as NewContractPayload
                    await db.client.query(`SELECT ${SCHEMA_NAME}.insert_contract($1,$2,$3,$4,$5,$6,$7,$8);`,[
                        op.id,
                        result.payload.contract_id,
                        result.payload.name,
                        result.payload.description,
                        result.payload.code,
                        ...(result.payload.storage_proof ? [
                            result.payload.storage_proof.hash,
                            result.payload.storage_proof.signature.sig,
                            result.payload.storage_proof.signature.bv
                        ]: [null, null, null])
                    ])
                    break
                case op_type_map.map.update_contract:
                    result.payload = result.payload as NewContractPayload
                    await db.client.query(`SELECT ${SCHEMA_NAME}.update_contract($1,$2,$3,$4,$5,$6);`,[
                        op.id,
                        result.payload.contract_id,
                        result.payload.code,
                        result.payload.storage_proof!.hash,
                        result.payload.storage_proof!.signature.sig,
                        result.payload.storage_proof!.signature.bv
                    ])
                    break
                case op_type_map.map.tx:
                    result.payload = result.payload as L1TxPayload
                    await db.client.query(`SELECT ${SCHEMA_NAME}.insert_l1_call_tx($1,$2,$3::SMALLINT[],$4,$5,$6::jsonb);`,[
                        op.id,
                        result.payload.callers.map(c => c.user),
                        result.payload.callers.map(c => c.auth),
                        result.payload.contract_id,
                        result.payload.action,
                        JSON.stringify([result.payload.payload])
                    ])
                    break
                case op_type_map.map.election_result:
                    result.payload = result.payload as ElectionPayload2
                    await db.client.query(`SELECT ${SCHEMA_NAME}.insert_election_result($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11);`,[
                        op.id,
                        result.user,
                        result.payload.epoch,
                        result.payload.data,
                        result.payload.signature.sig,
                        result.payload.signature.bv,
                        '{'+result.payload.members.map(m => m.account).join(',')+'}',
                        '{"'+result.payload.members.map(m => m.key).join('","')+'"}',
                        '{'+result.payload.members.map(m => m.weight).join(',')+'}',
                        result.payload.weight_total,
                        result.payload.voted_weight
                    ])
                    break
                case op_type_map.map.bridge_ref:
                    result.payload = result.payload as BridgeRefResult
                    await db.client.query(`SELECT ${SCHEMA_NAME}.update_withdrawal_statuses($1,$2,$3);`,['{'+result.payload.join(',')+'}','completed',result.block_num])
                    break
                default:
                    break
            }
        }
        return result.valid
    }
}

export default processor