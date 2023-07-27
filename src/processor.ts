import { cid as isCID } from 'is-ipfs'
import { CID } from 'multiformats/cid'
import randomDID from './did.js'
import { CUSTOM_JSON_IDS, SCHEMA_NAME, NETWORK_ID, MULTISIG_ACCOUNT } from './constants.js'
import db from './db.js'
import logger from './logger.js'
import { BlockPayload, ContractCommitmentPayload, DIDPayload, MultisigTxRefPayload, NewContractPayload, NodeAnnouncePayload, ParsedOp, TxTypes } from './processor_types.js'
import op_type_map from './operations.js'

const processor = {
    validateAndParse: async (op: any, ts: Date): Promise<ParsedOp> => {
        try {
            let parsed = JSON.parse(op.body)
            // sanitize and filter custom json
            // adjust operation field checking as necessary
            if ((parsed.type !== 'custom_json_operation' && parsed.type !== 'account_update_operation') ||
                !parsed.value)
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
                                did: proof.kid.split('#')[0]
                            }
                        } catch {
                            return { valid: false }
                        }
                        break
                    case 4:
                        // announce block
                        if (payload.net_id !== NETWORK_ID ||
                            typeof payload.block_hash !== 'string' ||
                            !isCID(payload.block_hash) ||
                            CID.parse(payload.block_hash).code !== 0x71)
                            return { valid: false }
                        details.payload = {
                            block_hash: payload.block_hash
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
                            CID.parse(payload.code).code !== 0x71)
                            return { valid: false }
                        details.payload = {
                            ref_id: payload.ref_id
                        }
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
                    witnessEnabled: proof && proof.witness && proof.witness.enabled
                }
                return details
            }
            // validate operation here
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
            let new_vsc_op = await db.client.query(`SELECT ${SCHEMA_NAME}.process_operation($1,$2,$3);`,[result.user, result.id, op_number])
            switch (op_number) {
                case op_type_map.map.announce_node:
                    pl = result.payload as NodeAnnouncePayload
                    await db.client.query(`SELECT ${SCHEMA_NAME}.update_witness($1,$2,$3,$4);`,[result.user,pl.did,pl.witnessEnabled,new_vsc_op.rows[0].process_operation])
                    break
                case op_type_map.map.enable_witness:
                    pl = result.payload as DIDPayload
                    await db.client.query(`SELECT ${SCHEMA_NAME}.update_witness($1,$2,$3,$4);`,[result.user,pl.did,true,new_vsc_op.rows[0].process_operation])
                    break
                case op_type_map.map.disable_witness:
                    pl = result.payload as DIDPayload
                    await db.client.query(`SELECT ${SCHEMA_NAME}.update_witness($1,$2,$3,$4);`,[result.user,null,false,new_vsc_op.rows[0].process_operation])
                    break
                case op_type_map.map.allow_witness:
                    pl = result.payload as DIDPayload
                    await db.client.query(`SELECT ${SCHEMA_NAME}.trust_did($1,$2);`,[pl.did,true])
                    break
                case op_type_map.map.disallow_witness:
                    pl = result.payload as DIDPayload
                    await db.client.query(`SELECT ${SCHEMA_NAME}.trust_did($1,$2);`,[pl.did,false])
                    break
                case op_type_map.map.announce_block:
                    pl = result.payload as BlockPayload
                    await db.client.query(`SELECT ${SCHEMA_NAME}.insert_block($1,$2);`,[new_vsc_op.rows[0].process_operation,pl.block_hash])
                    break
                case op_type_map.map.insert_contract:
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
                case op_type_map.map.custom_json:
                    // TODO what should be done here?
                    break
                default:
                    break
            }
        }
        return result.valid
    }
}

export default processor