import logger from '../logger.js'
import db from '../db.js'
import { L2PayloadTypes, ParsedOp, VscOp, BlockOp, ElectionPayload, OpBody, BridgeRefPayload, CustomJsonPayloads, BridgeRefResult } from '../processor_types.js'
import ipfs from './ipfs.js'
import { CID } from 'kubo-rpc-client'
import op_type_map from '../operations.js'
import { BridgeRef } from './ipfs_payload.js'
import { SCHEMA_NAME } from '../constants.js'

const processor = {
    validateAndParse: async (op: VscOp): Promise<ParsedOp<L2PayloadTypes>> => {
        // we know at this point that the operation looks valid as it has
        // been validated in main HAF app sync, however we perform further
        // validation and parsing on data only accessible in IPFS here.
        let parsed: OpBody = JSON.parse(op.body)
        let details: ParsedOp<L2PayloadTypes> = {
            valid: true,
            block_num: op.block_num
        }
        try {
            // these are all custom jsons, so we parse the json payload right away
            let payload: CustomJsonPayloads = JSON.parse(parsed.value.json)
            switch (op.op_type) {
                case op_type_map.map.propose_block:
                    // propose block
                    payload = payload as BlockOp
                    break
                case op_type_map.map.election_result:
                    // election result
                    payload = payload as ElectionPayload
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
                    break
                case op_type_map.map.election_result:
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