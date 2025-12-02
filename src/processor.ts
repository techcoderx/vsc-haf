import { CUSTOM_JSON_IDS, SCHEMA_NAME, NETWORK_ID, NETWORK_ID_ANNOUNCE, MULTISIG_ACCOUNT } from './constants.js'
import db from './db.js'
import logger from './logger.js'
import { NodeAnnouncePayload, Op, OpBody, ParsedOp, PayloadTypes, TxTypes } from './processor_types.js'
import op_type_map from './operations.js'

const processor = {
    validateAndParse: async (op: Op, ts: Date): Promise<ParsedOp<PayloadTypes>> => {
        try {
            let parsed: OpBody = JSON.parse(op.body)
            const msAcc = MULTISIG_ACCOUNT
            if (!parsed.value)
                return { valid: false }
            if (parsed.type === 'custom_json_operation') {
                let cjidx = CUSTOM_JSON_IDS.indexOf(parsed.value.id)
                const isSystemTx = [0,1].includes(cjidx)
                const isTss = parsed.value.id.startsWith('vsc.tss_')
                if (cjidx === -1 || !parsed.value.json)
                    return { valid: false }
                let user: string
                if (isSystemTx) {
                    if (parsed.value.required_auths.length === 0 || parsed.value.required_auths[0] !== msAcc)
                        return { valid: false }
                    else
                        user = msAcc
                } else {
                    if (parsed.value.required_auths.length > 0)
                        user = parsed.value.required_auths[0]
                    else
                        user = parsed.value.required_posting_auths[0]
                }
                let payload = JSON.parse(parsed.value.json)
                let details: ParsedOp<PayloadTypes> = {
                    valid: true,
                    id: op.id,
                    ts,
                    user,
                    block_num: op.block_num,
                    trx_in_block: op.trx_in_block,
                    op_pos: op.op_pos,
                    tx_type: TxTypes.CustomJSON,
                    op_type: cjidx
                }
                if (!isSystemTx && !isTss && payload.net_id !== NETWORK_ID)
                    return { valid: false }
                return details
            } else if (parsed.type === 'account_update_operation') {
                if (parsed.value.account === msAcc)
                    return {
                        valid: true,
                        id: op.id,
                        ts,
                        user: parsed.value.account,
                        block_num: op.block_num,
                        tx_type: TxTypes.AccountUpdate
                    }
                if (!parsed.value.json_metadata) return { valid: false }
                let payload = JSON.parse(parsed.value.json_metadata)
                let details: ParsedOp<NodeAnnouncePayload> = {
                    valid: true,
                    id: op.id,
                    ts,
                    user: parsed.value.account,
                    block_num: op.block_num,
                    tx_type: TxTypes.AccountUpdate
                }
                if (typeof payload.vsc_node !== 'object' || (payload.vsc_node.net_id !== NETWORK_ID_ANNOUNCE && payload.vsc_node.net_id !== NETWORK_ID))
                    return { valid: false }
                details.payload = {
                    peer_id: payload.vsc_node.peer_id,
                    peer_addrs: payload.vsc_node.peer_addrs,
                    version_id: payload.vsc_node.version_id,
                    git_commit: payload.vsc_node.git_commit,
                    protocol_version: payload.vsc_node.protocol_version,
                    gateway_key: payload.vsc_node.gateway_key,
                    witnessEnabled: typeof payload.vsc_node.witness === 'object' && payload.vsc_node.witness.enabled,
                } as NodeAnnouncePayload
                if (Array.isArray(payload.did_keys))
                    for (let i in payload.did_keys)
                        if (typeof payload.did_keys[i] === 'object' && payload.did_keys[i].t === 'consensus' && payload.did_keys[i].ct === 'DID-BLS' && typeof payload.did_keys[i].key === 'string') {
                            details.payload.consensus_did = payload.did_keys[i].key
                            break // use first consensus bls-did key
                        }
                return details
            } else if (parsed.type === 'transfer_operation') {
                if ((parsed.value.from !== msAcc && parsed.value.to !== msAcc))
                    return { valid: false }
                return {
                    valid: true,
                    id: op.id,
                    ts,
                    user: parsed.value.from !== msAcc ? parsed.value.from : parsed.value.to,
                    block_num: op.block_num,
                    tx_type: TxTypes.Transfer
                }
            } else if (parsed.type === 'transfer_to_savings_operation') {
                if ((parsed.value.from !== msAcc && parsed.value.to !== msAcc))
                    return { valid: false }
                return {
                    valid: true,
                    id: op.id,
                    ts,
                    user: parsed.value.from !== msAcc ? parsed.value.from : parsed.value.to,
                    block_num: op.block_num,
                    tx_type: TxTypes.TransferToSavings
                }
            } else if (parsed.type === 'transfer_from_savings_operation') {
                if ((parsed.value.from !== msAcc && parsed.value.to !== msAcc))
                    return { valid: false }
                return {
                    valid: true,
                    id: op.id,
                    ts,
                    user: parsed.value.from !== msAcc ? parsed.value.from : parsed.value.to,
                    block_num: op.block_num,
                    tx_type: TxTypes.TransferFromSavings
                }
            } else if (parsed.type === 'interest_operation') {
                if ((parsed.value.owner !== msAcc))
                    return { valid: false }
                return {
                    valid: true,
                    id: op.id,
                    ts,
                    user: msAcc,
                    block_num: op.block_num,
                    tx_type: TxTypes.HbdInterest
                }
            } else if (parsed.type === 'fill_transfer_from_savings_operation') {
                if ((parsed.value.from !== msAcc && parsed.value.to !== msAcc))
                    return { valid: false }
                return {
                    valid: true,
                    id: op.id,
                    ts,
                    user: parsed.value.from !== msAcc ? parsed.value.from : parsed.value.to,
                    block_num: op.block_num,
                    tx_type: TxTypes.FillTransferFromSavings
                }
            }
            return { valid: false }
        } catch (e) {
            logger.trace('Failed to parse operation, id:',op.id,'block:',op.block_num)
            logger.trace(e)
            return { valid: false }
        }
    },
    process: async (op: Op, ts: Date): Promise<boolean> => {
        let result = await processor.validateAndParse(op, ts)
        if (result.valid) {
            logger.trace('Processing op',result)
            let op_number = op_type_map.translate(result.tx_type!, result.op_type!, result.user === MULTISIG_ACCOUNT)
            let new_vsc_op = await db.client.query(`SELECT ${SCHEMA_NAME}.process_operation($1,$2,$3,$4);`,[result.user, result.id, op_number, result.ts])
            switch (op_number) {
                case op_type_map.map.announce_node:
                    let pl = result.payload as NodeAnnouncePayload
                    await db.client.query(`SELECT ${SCHEMA_NAME}.update_witness($1,$2,$3,$4::jsonb,$5,$6,$7,$8,$9,$10);`,[
                        result.user,
                        pl.consensus_did,
                        pl.peer_id,
                        JSON.stringify(pl.peer_addrs),
                        pl.version_id,
                        pl.git_commit,
                        pl.protocol_version,
                        pl.gateway_key,
                        pl.witnessEnabled,
                        new_vsc_op.rows[0].process_operation
                    ])
                    break
                default:
                    break
            }
        }
        return result.valid
    }
}

export default processor