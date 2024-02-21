import { cid as isCID } from 'is-ipfs'
import { CID } from 'multiformats/cid'
import randomDID from './did.js'
import { CUSTOM_JSON_IDS, SCHEMA_NAME, NETWORK_ID, MULTISIG_ACCOUNT, L1_ASSETS } from './constants.js'
import db from './db.js'
import logger from './logger.js'
import { BlockPayload, ContractCommitmentPayload, DIDPayload, DepositPayload, MultisigTxRefPayload, NewContractPayload, NodeAnnouncePayload, Op, ParsedOp, TxTypes } from './processor_types.js'
import op_type_map from './operations.js'

const processor = {
    validateAndParse: async (op: Op, ts: Date): Promise<ParsedOp> => {
        try {
            let parsed = JSON.parse(op.body)
            if (!parsed.value)
                return { valid: false }
            if (parsed.type === 'custom_json_operation') {
                let cjidx = CUSTOM_JSON_IDS.indexOf(parsed.value.id)
                if (cjidx === -1 ||
                    !Array.isArray(parsed.value.required_posting_auths) ||
                    parsed.value.required_posting_auths.length === 0 || // use posting auth only
                    !parsed.value.json)
                    return { valid: false }
                let payload = JSON.parse(parsed.value.json)
                let details: ParsedOp = {
                    valid: true,
                    id: op.id,
                    ts: ts,
                    user: parsed.value.required_posting_auths[0],
                    block_num: op.block_num,
                    tx_type: TxTypes.CustomJSON,
                    op_type: cjidx
                }
                switch (cjidx) {
                    case 0:
                        // enable witness
                        if (typeof payload.did !== 'string')
                            return { valid: false }
                        details.payload = {
                            did: payload.did
                        }
                        break
                    case 2:
                    case 3:
                        // allow/disallow witness
                        try {
                            if (typeof payload.proof !== 'object')
                                return { valid: false }
                            let proof = await randomDID.verifyJWS(payload.proof)
                            if (typeof proof.payload !== 'object' ||
                                !proof.payload.ts ||
                                proof.payload.net_id !== NETWORK_ID ||
                                typeof proof.payload.node_id !== 'string' ||
                                (Math.abs(details.ts!.getTime() - new Date(proof.payload.ts).getTime()) > 30*1000)
                            )
                                return { valid: false }
                            details.payload = {
                                did: proof.payload.node_id
                            }
                        } catch {
                            return { valid: false }
                        }
                        break
                    case 4:
                        // propose block
                        logger.trace('new block',payload)
                        if (payload.net_id !== NETWORK_ID ||
                            payload.experiment_id !== 2 ||
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
                    case 5:
                        // create contract
                        if (payload.net_id !== NETWORK_ID ||
                            typeof payload.name !== 'string' ||
                            typeof payload.manifest_id !== 'string' ||
                            !isCID(payload.manifest_id) ||
                            CID.parse(payload.manifest_id).code !== 0x70 ||
                            !isCID(payload.code) ||
                            CID.parse(payload.code).code !== 0x70)
                            return { valid: false }
                        details.payload = {
                            manifest_id: payload.manifest_id,
                            name: payload.name,
                            code: payload.code
                        }
                        break
                    case 6:
                    case 7:
                        // join/leave contract
                        if (payload.net_id !== NETWORK_ID ||
                            typeof payload.contract_id !== 'string' ||
                            typeof payload.node_identity !== 'string')
                            return { valid: false }
                        details.payload = {
                            contract_id: payload.contract_id,
                            node_identity: payload.node_identity
                        }
                        break
                    case 8:
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
                    case 10:
                        // withdrawal request
                        if (payload.net_id !== NETWORK_ID || isNaN(parseFloat(payload.amount)))
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
                if (!parsed.value.json_metadata) return { valid: false }
                let payload = JSON.parse(parsed.value.json_metadata)
                let details: ParsedOp = {
                    valid: true,
                    id: op.id,
                    ts: ts,
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
                details.payload = {
                    did: did,
                    witnessEnabled: proof && proof.witness && proof.witness.enabled,
                    git_commit: (proof && typeof proof.git_commit === 'string') ? (proof.git_commit as string).trim().slice(0,40) : ''
                }
                return details
            } else if (parsed.type === 'transfer_operation') {
                if ((parsed.value.from !== MULTISIG_ACCOUNT && parsed.value.to !== MULTISIG_ACCOUNT)|| !parsed.value.memo)
                    return { valid: false }
                let payload = JSON.parse(parsed.value.memo)
                let details: ParsedOp = {
                    valid: true,
                    id: op.id,
                    ts: ts,
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
        } catch {
            logger.trace('Failed to parse operation, id:',op.id,'block:',op.block_num)
            return { valid: false }
        }
    },
    process: async (op: any, ts: Date): Promise<boolean> => {
        let result = await processor.validateAndParse(op, ts)
        if (result.valid) {
            logger.trace('Processing op',result)
            let pl, op_number = op_type_map.translate(result.tx_type!, result.op_type!)
            let new_vsc_op = await db.client.query(`SELECT ${SCHEMA_NAME}.process_operation($1,$2,$3,$4);`,[result.user, result.id, op_number, result.ts])
            switch (op_number) {
                case op_type_map.map.announce_node:
                    pl = result.payload as NodeAnnouncePayload
                    await db.client.query(`SELECT ${SCHEMA_NAME}.update_witness($1,$2,$3,$4,$5);`,[result.user,pl.did,pl.witnessEnabled,new_vsc_op.rows[0].process_operation,pl.git_commit])
                    break
                case op_type_map.map.enable_witness:
                    pl = result.payload as DIDPayload
                    await db.client.query(`SELECT ${SCHEMA_NAME}.update_witness($1,$2,$3,$4,$5);`,[result.user,pl.did,true,new_vsc_op.rows[0].process_operation,null])
                    break
                case op_type_map.map.disable_witness:
                    pl = result.payload as DIDPayload
                    await db.client.query(`SELECT ${SCHEMA_NAME}.update_witness($1,$2,$3,$4,$5);`,[result.user,null,false,new_vsc_op.rows[0].process_operation,null])
                    break
                case op_type_map.map.propose_block:
                    pl = result.payload as BlockPayload
                    await db.client.query(`SELECT ${SCHEMA_NAME}.insert_block($1,$2,$3,$4,$5);`,[new_vsc_op.rows[0].process_operation,pl.block_hash,result.user,pl.signature.sig,pl.signature.bv])
                    break
                case op_type_map.map.create_contract:
                    pl = result.payload as NewContractPayload
                    await db.client.query(`SELECT ${SCHEMA_NAME}.insert_contract($1,$2,$3,$4);`,[new_vsc_op.rows[0].process_operation,pl.name,pl.manifest_id,pl.code])
                    break
                case op_type_map.map.join_contract:
                    pl = result.payload as ContractCommitmentPayload
                    await db.client.query(`SELECT ${SCHEMA_NAME}.update_contract_commitment($1,$2,$3);`,[pl.contract_id,pl.node_identity,true])
                    break
                case op_type_map.map.leave_contract:
                    pl = result.payload as ContractCommitmentPayload
                    await db.client.query(`SELECT ${SCHEMA_NAME}.update_contract_commitment($1,$2,$3);`,[pl.contract_id,pl.node_identity,false])
                    break
                case op_type_map.map.multisig_txref:
                    pl = result.payload as MultisigTxRefPayload
                    await db.client.query(`SELECT ${SCHEMA_NAME}.insert_multisig_txref($1,$2);`,[new_vsc_op.rows[0].process_operation,pl.ref_id])
                    break
                case op_type_map.map.custom_json:
                    // TODO what should be done here?
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