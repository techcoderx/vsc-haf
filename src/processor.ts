import { cid as isCID } from 'is-ipfs'
import { CID } from 'multiformats/cid'
import { encodePayload } from 'dag-jose-utils'
import { bech32 } from "bech32"
import randomDID from './did.js'
import { CUSTOM_JSON_IDS, SCHEMA_NAME, NETWORK_ID, MULTISIG_ACCOUNT, L1_ASSETS } from './constants.js'
import db from './db.js'
import logger from './logger.js'
import { BlockPayload, DepositPayload, ElectionPayload, MultisigTxRefPayload, NewContractPayload, NodeAnnouncePayload, Op, ParsedOp, PayloadTypes, TxTypes } from './processor_types.js'
import op_type_map from './operations.js'
import { isValidL1PubKey } from './utils/crypto.js'

const processor = {
    validateAndParse: async (op: Op): Promise<ParsedOp<PayloadTypes>> => {
        try {
            let parsed = JSON.parse(op.body)
            if (!parsed.value)
                return { valid: false }
            if (parsed.type === 'custom_json_operation') {
                let cjidx = CUSTOM_JSON_IDS.indexOf(parsed.value.id)
                let requiresActiveAuth = cjidx === 0 || cjidx === 1 || cjidx === 4
                if (cjidx === -1 || !parsed.value.json)
                    return { valid: false }

                // block proposals and contract creation requires active auth (possibly more?)
                if (requiresActiveAuth && (!Array.isArray(parsed.value.required_auths) ||
                    parsed.value.required_auths.length === 0))
                    return { valid: false }

                // everything else requires posting auth
                else if (!requiresActiveAuth && (!Array.isArray(parsed.value.required_posting_auths) ||
                    parsed.value.required_posting_auths.length === 0))
                    return { valid: false }
                let payload = JSON.parse(parsed.value.json)
                if (payload.net_id !== NETWORK_ID)
                    return { valid: false }
                let details: ParsedOp<PayloadTypes> = {
                    valid: true,
                    id: op.id,
                    ts: op.timestamp,
                    user: requiresActiveAuth ? parsed.value.required_auths[0] : parsed.value.required_posting_auths[0],
                    block_num: op.block_num,
                    trx_in_block: op.trx_in_block,
                    op_pos: op.op_pos,
                    tx_type: TxTypes.CustomJSON,
                    op_type: cjidx
                }
                switch (cjidx) {
                    case 0:
                        // propose block
                        if (payload.replay_id !== 2 ||
                            typeof payload.signed_block !== 'object' ||
                            !isCID(payload.signed_block.block) ||
                            CID.parse(payload.signed_block.block).code !== 0x71 ||
                            typeof payload.signed_block.signature !== 'object' ||
                            typeof payload.signed_block.signature.sig !== 'string' ||
                            typeof payload.signed_block.signature.bv !== 'string')
                            return { valid: false }
                        details.payload = {
                            block_hash: payload.signed_block.block,
                            signature: {
                                sig: payload.signed_block.signature.sig,
                                bv: payload.signed_block.signature.bv
                            }
                        }
                        break
                    case 1:
                        // create contract
                        if (!isCID(payload.code) ||
                            CID.parse(payload.code).code !== 0x55)
                            return { valid: false }
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
                        break
                    case 2:
                    case 3:
                        // l1 contract calls
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
                        details.payload = {
                            epoch: payload.epoch,
                            data: payload.data,
                            signature: payload.signature
                        }
                        break
                    case 5:
                        // multisig_txref
                        if (details.user !== MULTISIG_ACCOUNT ||
                            typeof payload.ref_id !== 'string' ||
                            !isCID(payload.ref_id) ||
                            CID.parse(payload.ref_id).code !== 0x71)
                            return { valid: false }
                        details.payload = {
                            ref_id: payload.ref_id
                        }
                        break
                    case 6:
                        // withdrawal request
                        if (isNaN(parseFloat(payload.amount)))
                            return { valid: false }
                        details.payload = {
                            amount: parseFloat(payload.amount),
                            asset: 0 // not sure
                        }
                        break
                    default:
                        break
                }
                return details
            } else if (parsed.type === 'account_update_operation') {
                if (parsed.value.account === MULTISIG_ACCOUNT)
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
                if ((parsed.value.from !== MULTISIG_ACCOUNT && parsed.value.to !== MULTISIG_ACCOUNT)|| !parsed.value.memo)
                    return { valid: false }
                let payload = JSON.parse(parsed.value.memo)
                let details: ParsedOp<DepositPayload> = {
                    valid: true,
                    id: op.id,
                    ts: op.timestamp,
                    block_num: op.block_num,
                    tx_type: TxTypes.Transfer
                }
                if (parsed.value.to === MULTISIG_ACCOUNT) {
                    // deposit
                    details.op_type = 0
                    details.user = parsed.value.from
                    if (payload.net_id !== NETWORK_ID || payload.action !== 'deposit')
                        return { valid: false }
                    details.payload = {
                        amount: parseInt(parsed.value.amount.amount),
                        asset: L1_ASSETS.indexOf(parsed.value.amount.nai)
                    }
                    if (payload.contract_id && typeof payload.contract_id === 'string')
                        details.payload.contract_id = payload.contract_id
                    if (details.payload.asset === -1)
                        return { valid: false } // this should not happen
                    return details
                } else if (parsed.value.from === MULTISIG_ACCOUNT) {
                    // withdrawal
                    details.op_type = 1
                    details.user = parsed.value.to
                    details.payload = {
                        amount: parseInt(parsed.value.amount.amount),
                        asset: L1_ASSETS.indexOf(parsed.value.amount.nai)
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
    process: async (op: any): Promise<boolean> => {
        let result = await processor.validateAndParse(op)
        if (result.valid) {
            logger.trace('Processing op',result)
            let pl, op_number = op_type_map.translate(result.tx_type!, result.op_type!, result.user === MULTISIG_ACCOUNT)
            let new_vsc_op = await db.client.query(`SELECT ${SCHEMA_NAME}.process_operation($1,$2,$3,$4);`,[result.user, result.id, op_number, result.ts])
            switch (op_number) {
                case op_type_map.map.announce_node:
                    pl = result.payload as NodeAnnouncePayload
                    await db.client.query(`SELECT ${SCHEMA_NAME}.update_witness($1,$2,$3,$4,$5,$6,$7,$8,$9);`,[result.user,pl.did,pl.consensus_did,pl.sk_posting,pl.sk_active,pl.sk_owner,pl.witnessEnabled,new_vsc_op.rows[0].process_operation,pl.git_commit])
                    break
                case op_type_map.map.propose_block:
                    pl = result.payload as BlockPayload
                    await db.client.query(`SELECT ${SCHEMA_NAME}.insert_block($1,$2,$3,$4,$5);`,[new_vsc_op.rows[0].process_operation,pl.block_hash,result.user,pl.signature.sig,pl.signature.bv])
                    break
                case op_type_map.map.create_contract:
                    pl = result.payload as NewContractPayload
                    await db.client.query(`SELECT ${SCHEMA_NAME}.insert_contract($1,$2,$3,$4,$5);`,[new_vsc_op.rows[0].process_operation,pl.contract_id,pl.name,pl.description,pl.code])
                    break
                case op_type_map.map.tx:
                    // TODO process op
                    break
                case op_type_map.map.election_result:
                    pl = result.payload as ElectionPayload
                    await db.client.query(`SELECT ${SCHEMA_NAME}.process_election_result($1,$2,$3,$4,$5,$6);`,[new_vsc_op.rows[0].process_operation,result.user,pl.epoch,pl.data,pl.signature.sig,pl.signature.bv])
                    break
                case op_type_map.map.multisig_txref:
                    pl = result.payload as MultisigTxRefPayload
                    await db.client.query(`SELECT ${SCHEMA_NAME}.insert_multisig_txref($1,$2);`,[new_vsc_op.rows[0].process_operation,pl.ref_id])
                    break
                case op_type_map.map.deposit:
                    pl = result.payload as DepositPayload
                    await db.client.query(`SELECT ${SCHEMA_NAME}.insert_deposit($1,$2,$3,$4);`,[new_vsc_op.rows[0].process_operation,pl.amount,pl.asset,pl.contract_id])
                    break
                case op_type_map.map.withdrawal:
                    pl = result.payload as DepositPayload
                    await db.client.query(`SELECT ${SCHEMA_NAME}.insert_withdrawal($1,$2,$3,$4);`,[new_vsc_op.rows[0].process_operation,pl.amount,pl.asset,pl.contract_id])
                    break
                default:
                    break
            }
        }
        return result.valid
    }
}

export default processor