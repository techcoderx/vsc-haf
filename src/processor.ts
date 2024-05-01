import { CID } from 'multiformats/cid'
import { bech32 } from "bech32"
import randomDID from './did.js'
import { CUSTOM_JSON_IDS, SCHEMA_NAME, NETWORK_ID, MULTISIG_ACCOUNT, L1_ASSETS, APP_CONTEXT, REQUIRES_ACTIVE, START_BLOCK, ANY_AUTH, CONTRACT_DATA_AVAILABLITY_PROOF_REQUIRED_HEIGHT, MULTISIG_ACCOUNT_2 } from './constants.js'
import db from './db.js'
import logger from './logger.js'
import { DepositPayload, MultisigTxRefPayload, NodeAnnouncePayload, Op, OpBody, ParsedOp, PayloadTypes, TxTypes } from './processor_types.js'
import op_type_map from './operations.js'
import { isValidL1PubKey } from './utils/crypto.js'
import { isCID } from './subindexer/ipfs_dag.js'

const getMultisigAccount = (block_num: number) => {
    if (block_num < 85000000)
        return MULTISIG_ACCOUNT
    else
        return MULTISIG_ACCOUNT_2
}

const processor = {
    validateAndParse: async (op: Op): Promise<ParsedOp<PayloadTypes>> => {
        try {
            let parsed: OpBody = JSON.parse(op.body)
            const msAcc = getMultisigAccount(op.block_num)
            if (!parsed.value)
                return { valid: false }
            if (parsed.type === 'custom_json_operation') {
                let cjidx = CUSTOM_JSON_IDS.indexOf(parsed.value.id)
                let requiresActiveAuth = REQUIRES_ACTIVE.includes(cjidx)
                let anyAuth = ANY_AUTH.includes(cjidx)
                if (cjidx === -1 || !parsed.value.json)
                    return { valid: false }

                let user: string
                // block proposals and contract creation requires active auth (possibly more?)
                if (requiresActiveAuth) {
                    if (!Array.isArray(parsed.value.required_auths) || parsed.value.required_auths.length === 0)
                        return { valid: false }
                    else
                        user = parsed.value.required_auths[0]
                } else if (anyAuth) {
                    // contract calls from l1 can use both
                    // either one of these must be present, otherwise it wouldn't be a valid L1 tx that can ever reach here
                    user = parsed.value.required_auths.length > 0 ? parsed.value.required_auths[0] : parsed.value.required_posting_auths[0]
                } else {
                    // everything else requires posting auth
                    if (!Array.isArray(parsed.value.required_posting_auths) || parsed.value.required_posting_auths.length === 0)
                        return { valid: false }
                    else
                        user = parsed.value.required_posting_auths[0]
                }
                let payload = JSON.parse(parsed.value.json)
                let details: ParsedOp<PayloadTypes> = {
                    valid: true,
                    id: op.id,
                    ts: op.timestamp,
                    user: user,
                    block_num: op.block_num,
                    trx_in_block: op.trx_in_block,
                    op_pos: op.op_pos,
                    tx_type: TxTypes.CustomJSON,
                    op_type: cjidx
                }
                if (details.user !== msAcc && payload.net_id !== NETWORK_ID)
                    return { valid: false }
                let sig: Buffer, bv: Buffer, merkle: Buffer
                switch (cjidx) {
                    case 0:
                        // propose block
                        if (payload.replay_id !== 2 ||
                            typeof payload.signed_block !== 'object' ||
                            !isCID(payload.signed_block.block) ||
                            CID.parse(payload.signed_block.block).code !== 0x71 ||
                            typeof payload.signed_block.headers !== 'object' ||
                            !Array.isArray(payload.signed_block.headers.br) ||
                            payload.signed_block.headers.br.length !== 2 ||
                            !Number.isInteger(payload.signed_block.headers.br[0]) ||
                            !Number.isInteger(payload.signed_block.headers.br[1]) ||
                            payload.signed_block.headers.br[0] < START_BLOCK ||
                            payload.signed_block.headers.br[1] < payload.signed_block.headers.br[0] ||
                            (payload.signed_block.headers.prevb && typeof payload.signed_block.headers.prevb !== 'string') ||
                            typeof payload.signed_block.merkle_root !== 'string' ||
                            typeof payload.signed_block.signature !== 'object' ||
                            typeof payload.signed_block.signature.sig !== 'string' ||
                            typeof payload.signed_block.signature.bv !== 'string')
                            return { valid: false }
                        sig = Buffer.from(payload.signed_block.signature.sig, 'base64url')
                        bv = Buffer.from(payload.signed_block.signature.bv, 'base64url')
                        merkle = Buffer.from(payload.signed_block.merkle_root, 'base64url')
                        if (sig.length !== 96 || merkle.length !== 32)
                            return { valid: false }
                        break
                    case 1:
                        // create contract
                        if (!isCID(payload.code))
                            return { valid: false }
                        const contractCode = CID.parse(payload.code)
                        if (contractCode.code !== 0x55 && contractCode.code !== 0x71)
                            return { valid: false }
                        if (details.block_num! >= CONTRACT_DATA_AVAILABLITY_PROOF_REQUIRED_HEIGHT) {
                            if (typeof payload.storage_proof !== 'object' ||
                                typeof payload.storage_proof.hash !== 'string' ||
                                typeof payload.storage_proof.signature !== 'object' ||
                                typeof payload.storage_proof.signature.sig !== 'string' ||
                                typeof payload.storage_proof.signature.bv !== 'string' ||
                                !isCID(payload.storage_proof.hash))
                                return { valid: false }
                            const proofCID = CID.parse(payload.storage_proof.hash)
                            if (proofCID.code !== 0x71)
                                return { valid: false }
                            sig = Buffer.from(payload.storage_proof.signature.sig, 'base64url')
                            bv = Buffer.from(payload.storage_proof.signature.bv, 'base64url')
                            if (sig.length !== 96)
                                return { valid: false }
                        }
                        break
                    case 2:
                    case 3:
                        // l1 contract calls
                        if (typeof payload.tx !== 'object' ||
                            typeof payload.tx.action !== 'string' ||
                            typeof payload.tx.contract_id !== 'string' ||
                            payload.tx.contract_id.length > 68 ||
                            !payload.tx.contract_id.startsWith('vs4'))
                            return { valid: false }
                        bech32.decode(payload.tx.contract_id)
                        // we might not want to check for contract existence here
                        // as it is possible that the contract may be deployed on L2
                        // so we only process this tx type on subindexer, which is
                        // also easier to do anyway in an event a subindexer reindex
                        // is required, the tables can be easily truncated.
                        break
                    case 4:
                        // election result
                        if (typeof payload.data !== 'string' ||
                            !isCID(payload.data) ||
                            CID.parse(payload.data).code !== 0x71 ||
                            !Number.isInteger(payload.epoch) ||
                            payload.epoch < 0 ||
                            typeof payload.signature !== 'object' ||
                            typeof payload.signature.sig !== 'string' ||
                            typeof payload.signature.bv !== 'string')
                            return { valid: false }
                        sig = Buffer.from(payload.signature.sig, 'base64url')
                        bv = Buffer.from(payload.signature.bv, 'base64url')
                        if (sig.length !== 96)
                            return { valid: false }
                        details.payload = {
                            epoch: payload.epoch,
                            data: payload.data,
                            net_id: payload.net_id,
                            signature: { sig, bv }
                        }
                        break
                    case 5:
                        // multisig_txref
                        if (details.user !== msAcc ||
                            typeof payload.ref_id !== 'string' ||
                            !isCID(payload.ref_id) ||
                            CID.parse(payload.ref_id).code !== 0x71)
                            return { valid: false }
                        details.payload = {
                            ref_id: payload.ref_id
                        }
                        break
                    case 6:
                        // bridge_ref
                        if (details.user !== msAcc ||
                            typeof payload.ref_id !== 'string' ||
                            !isCID(payload.ref_id) ||
                            CID.parse(payload.ref_id).code !== 0x71)
                            return { valid: false }
                        details.payload = {
                            ref_id: payload.ref_id
                        }
                        break
                    default:
                        break
                }
                return details
            } else if (parsed.type === 'account_update_operation') {
                if (parsed.value.account === msAcc)
                    return {
                        valid: true,
                        id: op.id,
                        ts: op.timestamp,
                        user: parsed.value.account,
                        block_num: op.block_num,
                        tx_type: TxTypes.AccountUpdate
                    }
                if (!parsed.value.json_metadata) return { valid: false }
                let payload = JSON.parse(parsed.value.json_metadata)
                let details: ParsedOp<NodeAnnouncePayload> = {
                    valid: true,
                    id: op.id,
                    ts: op.timestamp,
                    user: parsed.value.account,
                    block_num: op.block_num,
                    tx_type: TxTypes.AccountUpdate
                }
                if (!payload.vsc_node || !payload.vsc_node.signed_proof || !payload.vsc_node.signed_proof.payload || !payload.vsc_node.signed_proof.signatures)
                    return { valid: false }
                const {payload: proof, kid} = await randomDID.verifyJWS(payload.vsc_node.signed_proof)
                const [did] = kid.split('#')
                if (proof && proof.net_id !== NETWORK_ID)
                    return { valid: false }
                const hasWitObj = proof && typeof proof.witness === 'object'
                const hasSKeys = hasWitObj && typeof proof.witness.signing_keys === 'object'
                details.payload = {
                    did: did,
                    witnessEnabled: hasWitObj && proof.witness.enabled,
                    git_commit: (proof && typeof proof.git_commit === 'string') ? (proof.git_commit as string).trim().slice(0,40) : ''
                } as NodeAnnouncePayload
                if (Array.isArray(payload.did_keys))
                    for (let i in payload.did_keys)
                        if (typeof payload.did_keys[i] === 'object' && payload.did_keys[i].t === 'consensus' && payload.did_keys[i].ct === 'DID-BLS' && typeof payload.did_keys[i].key === 'string') {
                            details.payload.consensus_did = payload.did_keys[i].key
                            break // use first consensus bls-did key
                        }
                if (hasSKeys) {
                    details.payload.sk_posting = isValidL1PubKey(proof.witness.signing_keys.posting) ? proof.witness.signing_keys.posting : null,
                    details.payload.sk_active = isValidL1PubKey(proof.witness.signing_keys.active) ? proof.witness.signing_keys.active : null,
                    details.payload.sk_owner = isValidL1PubKey(proof.witness.signing_keys.owner) ? proof.witness.signing_keys.owner : null
                }
                return details
            } else if (parsed.type === 'transfer_operation') {
                if ((parsed.value.from !== msAcc && parsed.value.to !== msAcc))
                    return { valid: false }
                let details: ParsedOp<DepositPayload> = {
                    valid: true,
                    id: op.id,
                    ts: op.timestamp,
                    block_num: op.block_num,
                    tx_type: TxTypes.Transfer
                }
                if (parsed.value.to === msAcc) {
                    let payload: any = {}
                    try {
                        payload = JSON.parse(parsed.value.memo)
                    } catch {
                        const queryString = new URLSearchParams(parsed.value.memo)
                        for(let [key, value] of queryString.entries())
                            payload[key] = value
                    }
                    details.user = parsed.value.from
                    if (typeof payload.action === 'string' && payload.action === 'withdraw') {
                        let amountToWithdraw = parseFloat(payload.amount)
                        if (isNaN(amountToWithdraw) || amountToWithdraw <= 0)
                            return { valid: false }
                        // withdrawal request
                        details.op_type = 2
                        details.payload = {
                            amount: Math.round(parseFloat(amountToWithdraw.toFixed(3))*1000),
                            amount2: parseInt(parsed.value.amount.amount),
                            asset: L1_ASSETS.indexOf(parsed.value.amount.nai),
                            owner: details.user
                        }
                    } else {
                        if(typeof payload.to === 'string') {
                            if (payload.to.startsWith('did:') && payload.to.length <= 78)
                                payload.owner = payload.to
                            else if (payload.to.startsWith('@') && payload.to.length <= 17 &&
                                (await db.client.query(`SELECT * FROM hive.${APP_CONTEXT}_accounts WHERE name=$1;`,[payload.to.replace('@','')])).rowCount! > 0)
                                payload.owner = payload.to.replace('@','')
                            else
                                payload.owner = parsed.value.from
                        } else {
                            payload.owner = parsed.value.from
                        }
                        // deposit
                        details.op_type = 0
                        details.payload = {
                            amount: parseInt(parsed.value.amount.amount),
                            asset: L1_ASSETS.indexOf(parsed.value.amount.nai),
                            owner: payload.owner
                        }
                    }
                    if (details.payload.asset === -1)
                        return { valid: false } // this should not happen
                    return details
                } else if (parsed.value.from === msAcc) {
                    // withdrawal
                    details.op_type = 1
                    details.user = parsed.value.to
                    details.payload = {
                        amount: parseInt(parsed.value.amount.amount),
                        asset: L1_ASSETS.indexOf(parsed.value.amount.nai),
                        owner: details.user
                    }
                    if (details.payload.asset === -1)
                        return { valid: false } // again, this should not happen
                    return details
                }
            }
            return { valid: false }
        } catch (e) {
            logger.trace('Failed to parse operation, id:',op.id,'block:',op.block_num)
            logger.trace(e)
            return { valid: false }
        }
    },
    process: async (op: Op): Promise<boolean> => {
        let result = await processor.validateAndParse(op)
        if (result.valid) {
            logger.trace('Processing op',result)
            let pl, op_number = op_type_map.translate(result.tx_type!, result.op_type!, result.user === getMultisigAccount(op.block_num))
            let new_vsc_op = await db.client.query(`SELECT ${SCHEMA_NAME}.process_operation($1,$2,$3,$4);`,[result.user, result.id, op_number, result.ts])
            switch (op_number) {
                case op_type_map.map.announce_node:
                    pl = result.payload as NodeAnnouncePayload
                    await db.client.query(`SELECT ${SCHEMA_NAME}.update_witness($1,$2,$3,$4,$5,$6,$7,$8,$9);`,[result.user,pl.did,pl.consensus_did,pl.sk_posting,pl.sk_active,pl.sk_owner,pl.witnessEnabled,new_vsc_op.rows[0].process_operation,pl.git_commit])
                    break
                case op_type_map.map.multisig_txref:
                    pl = result.payload as MultisigTxRefPayload
                    await db.client.query(`SELECT ${SCHEMA_NAME}.insert_multisig_txref($1,$2);`,[new_vsc_op.rows[0].process_operation,pl.ref_id])
                    break
                case op_type_map.map.deposit:
                    pl = result.payload as DepositPayload
                    await db.client.query(`SELECT ${SCHEMA_NAME}.insert_deposit($1,$2,$3,$4,$5);`,[new_vsc_op.rows[0].process_operation,pl.amount,pl.asset,pl.owner,pl.owner!.startsWith('did:') ? 'did' : 'hive'])
                    break
                case op_type_map.map.withdrawal:
                    pl = result.payload as DepositPayload
                    await db.client.query(`SELECT ${SCHEMA_NAME}.insert_withdrawal($1,$2,$3,$4);`,[new_vsc_op.rows[0].process_operation,pl.amount,pl.asset,result.user])
                    break
                case op_type_map.map.withdrawal_request:
                    pl = result.payload as DepositPayload
                    await db.client.query(`SELECT ${SCHEMA_NAME}.insert_withdrawal_request($1,$2,$3,$4,$5);`,[new_vsc_op.rows[0].process_operation,pl.amount,pl.amount2,pl.asset,result.user])
                    break
                default:
                    break
            }
        }
        return result.valid
    }
}

export default processor