import { cid as isCID } from 'is-ipfs'
import { CID } from 'multiformats/cid'
import randomDID from 'did.js'
import { CUSTOM_JSON_IDS, SCHEMA_NAME, NETWORK_ID } from './constants.js'
import db from './db.js'
import logger from './logger.js'
import { ParsedOp, TxTypes } from './processor_types.js'

const processor = {
    validateAndParse: async (op: any): Promise<ParsedOp> => {
        try {
            let parsed = JSON.parse(op.body)
            // sanitize and filter custom json
            // adjust operation field checking as necessary
            if (parsed.type !== 'custom_json_operation' ||
                parsed.type !== 'account_update_operation' ||
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
                    ts: new Date(op.created_at),
                    user: parsed.value.required_posting_auths[0],
                    block_num: op.block_num,
                    tx_hash: op.trx_id,
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
                    default:
                        break
                }
                return details
            } else if (parsed.type === 'account_update_operation') {
                let payload = JSON.parse(parsed.value.json_metadata)
                let details: ParsedOp = {
                    valid: true,
                    ts: new Date(op.created_at),
                    user: parsed.value.account,
                    block_num: op.block_num,
                    tx_hash: op.trx_id,
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
    process: async (op: any): Promise<boolean> => {
        let result = await processor.validateAndParse(op)
        if (result.valid) {
            logger.trace('Processing op',result)
            // call the appropriate PL/pgSQL here to process operation
            await db.client.query(`SELECT ${SCHEMA_NAME}.process_tx($1);`,[result.user])
        }
        return result.valid
    }
}

export default processor