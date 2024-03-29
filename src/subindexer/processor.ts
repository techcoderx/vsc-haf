import logger from '../logger.js'
import db from '../db.js'
import { L2PayloadTypes, ParsedOp, VscOp, BlockOp, OpBody, BridgeRefPayload, CustomJsonPayloads, BridgeRefResult, ElectionOp, ElectionPayload, ElectionMember, ShuffledSchedule, UnsignedBlock, BlockPayload, L1CallTxOp, L1TxPayload } from '../processor_types.js'
import { BlockScheduleParams, WitnessConsensusDid } from '../psql_types.js'
import ipfs from './ipfs.js'
import { CID } from 'kubo-rpc-client'
import { createDag, isCID } from './ipfs_dag.js'
import { BlsCircuit, initBls } from '../utils/bls-did.js'
import op_type_map from '../operations.js'
import { AnchorRefBody, AnchorRefHead, BlockBody, BridgeRef, ContractCallBody, ContractOutBody } from './ipfs_payload.js'
import { APP_CONTEXT, EPOCH_LENGTH, ROUND_LENGTH, SCHEMA_NAME, SUPERMAJORITY } from '../constants.js'
import { shuffle } from '../utils/shuffle-seed.js'

await initBls()

const schedule: {
    shuffled?: ShuffledSchedule[] | null
    height?: number
    epoch?: number
} = {}

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
            block_num: op.block_num
        }
        try {
            let payload: CustomJsonPayloads = JSON.parse(parsed.value.json)
            let sig: Buffer, bv: Buffer, merkle: Buffer
            switch (op.op_type) {
                case op_type_map.map.propose_block:
                    // propose block
                    payload = payload as BlockOp
                    sig = Buffer.from(payload.signed_block.signature.sig, 'base64url')
                    bv = Buffer.from(payload.signed_block.signature.bv, 'base64url')
                    merkle = Buffer.from(payload.signed_block.merkle_root, 'base64url')
                    const witnessSet = await db.client.query<WitnessConsensusDid>(`SELECT * FROM ${SCHEMA_NAME}.get_members_at_block($1);`,[op.block_num])
                    const witnessKeyset = witnessSet.rows.map(m => m.consensus_did)
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
                        const {circuit, bs} = BlsCircuit.deserializeRaw(unsignedBlock, sig, bv, witnessKeyset)
                        const pubKeys = []
                        for(let pub of circuit.aggPubKeys)
                            pubKeys.push(pub[0])
                        circuit.setAgg(pubKeys)
                        const isValid = await circuit.verify((await createDag(unsignedBlock)).bytes)
                        const blockCIDShort = `${payload.signed_block.block.substring(0,12)}...${payload.signed_block.block.slice(-6)}`
                        logger.debug(`Block ${blockCIDShort} by ${witnessSlot.name}: ${bs.toString(2)} ${isValid}`)
                        if (isValid && pubKeys.length/witnessKeyset.length >= SUPERMAJORITY) {
                            // vsc-node does not currently check previous block header when syncing
                            // if we do check here, as the testnet genesis block isn't valid (published way out of schedule)
                            // therefore every block thereafter would be invalid
                            details.payload = {
                                block_hash: payload.signed_block.block,
                                block_header_cid: (await createDag(unsignedBlock)).toString(),
                                br: payload.signed_block.headers.br,
                                merkle_root: merkle,
                                signature: { sig, bv },
                                txs: []
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
                                    ![1,2,5].includes(blockTxs.txs[t].type)) {
                                    logger.warn(`Ignoring invalid tx at index ${t} in block ${blockCIDShort}`)
                                    continue
                                }
                                try {
                                    if (blockTxs.txs[t].type === 1) {
                                        const txBody: ContractCallBody = (await ipfs.dag.get(CID.parse(blockTxs.txs[t].id))).value
                                        // contract call
                                        if (typeof txBody.headers !== 'object' ||
                                            typeof txBody.headers.nonce !== 'number' ||
                                            !Array.isArray(txBody.headers.required_auths) ||
                                            typeof txBody.tx !== 'object' ||
                                            typeof txBody.tx.action !== 'string' ||
                                            typeof txBody.tx.contract_id !== 'string') {
                                            logger.warn(`Ignoring malformed contract call tx at index ${t} in block ${blockCIDShort}`)
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
                                            index: parseInt(t),
                                            contract_id: txBody.tx.contract_id,
                                            action: txBody.tx.action,
                                            payload: [txBody.tx.payload],
                                            callers: txBody.headers.required_auths,
                                            nonce: txBody.headers.nonce
                                        })
                                    } else if (blockTxs.txs[t].type === 2) {
                                        const txBody: ContractOutBody = (await ipfs.dag.get(CID.parse(blockTxs.txs[t].id))).value
                                        // contract output
                                        if (typeof txBody.contract_id !== 'string' ||
                                            !Array.isArray(txBody.inputs) ||
                                            typeof txBody.io_gas !== 'number' ||
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
                    const d = {
                        data: payload.data,
                        epoch: payload.epoch,
                        net_id: payload.net_id
                    }
                    // logger.trace(membersAtSlotStart.rows)
                    const keyset = membersAtSlotStart.rows.map(m => m.consensus_did)
                    const {circuit, bs} = BlsCircuit.deserializeRaw(d, sig, bv, keyset)
                    const pubKeys = []
                    for(let pub of circuit.aggPubKeys)
                        pubKeys.push(pub[0])
                    circuit.setAgg(pubKeys)
                    const isValid = await circuit.verify((await createDag(d)).bytes)
                    logger.debug(`Epoch ${d.epoch} election: ${bs.toString(2)} ${isValid}`)
                    if (isValid && (((pubKeys.length / members.rowCount!) > SUPERMAJORITY) || payload.epoch === 0)) {
                        const electedMembers: { members: ElectionMember<string>[] } = (await ipfs.dag.get(CID.parse(payload.data))).value
                        if (!Array.isArray(electedMembers.members))
                            return { valid: false }
                        const validatedElectedMembers: ElectionMember<number>[] = []
                        for (let m in electedMembers.members) {
                            if (typeof electedMembers.members[m].account !== 'string' || typeof electedMembers.members[m].key !== 'string')
                                continue
                            const accountExists = await db.client.query(`SELECT * FROM hive.${APP_CONTEXT}_accounts WHERE name=$1;`,[electedMembers.members[m].account])
                            if (accountExists.rows.length === 0)
                                continue
                            validatedElectedMembers.push({
                                account: accountExists.rows[0].id as number,
                                key: electedMembers.members[m].key
                            })
                        }
                        details.payload = {
                            ...d,
                            signature: { sig, bv },
                            members: validatedElectedMembers
                        } as ElectionPayload
                    } else
                        return { valid: false }
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
                    await db.client.query(`SELECT ${SCHEMA_NAME}.push_block($1,$2,$3,$4,$5,$6,$7,$8,$9,$10::jsonb);`,[
                        op.id,
                        result.user,
                        result.payload.block_hash,
                        result.payload.block_header_cid,
                        result.payload.br[0],
                        result.payload.br[1],
                        result.payload.merkle_root,
                        result.payload.signature.sig,
                        result.payload.signature.bv,
                        JSON.stringify(result.payload.txs)
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
                    result.payload = result.payload as ElectionPayload
                    await db.client.query(`SELECT ${SCHEMA_NAME}.insert_election_result($1,$2,$3,$4,$5,$6,$7,$8);`,[
                        op.id,
                        result.user,
                        result.payload.epoch,
                        result.payload.data,
                        result.payload.signature.sig,
                        result.payload.signature.bv,
                        '{'+result.payload.members!.map(m => m.account).join(',')+'}',
                        '{"'+result.payload.members!.map(m => m.key).join('","')+'"}'
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