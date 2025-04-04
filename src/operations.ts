import db from './db.js'
import logger from './logger.js'
import { TxTypes } from './processor_types.js'
import { CUSTOM_JSON_IDS, SCHEMA_NAME } from './constants.js'
import { L1OpTypes } from './psql_types.js'

type OpTypeIDMap = {
    [key: string]: number
}

type OpTypeMod = {
    map: OpTypeIDMap
    retrieveMap: () => Promise<void>,
    translate: (tx_type: TxTypes, idx: number, is_ms_account: boolean) => number
}

// op_type -> id mapping
const op_type_map: OpTypeMod = {
    map: {},
    retrieveMap: async (): Promise<void> => {
        let op_types = await db.client.query<L1OpTypes>(`SELECT * FROM ${SCHEMA_NAME}.l1_operation_types;`)
        for (let i in op_types.rows)
            op_type_map.map[op_types.rows[i].op_name] = op_types.rows[i].id
        logger.debug('Loaded op_type -> id mapping, count: '+op_types.rowCount)
        logger.trace(op_type_map.map)
    },
    translate: (tx_type: TxTypes, idx: number = -1, is_ms_account = false): number => {
        if (tx_type === TxTypes.AccountUpdate) {
            if (is_ms_account)
                return op_type_map.map.rotate_multisig
            else
                return op_type_map.map.announce_node
        }
        else if (tx_type === TxTypes.CustomJSON) {
            let cjtype = CUSTOM_JSON_IDS[idx].split('.')[1]
            return op_type_map.map[cjtype]
        } else if (tx_type === TxTypes.Transfer)
            return op_type_map.map.transfer
        else if (tx_type === TxTypes.TransferToSavings)
            return op_type_map.map.transfer_to_savings
        else if (tx_type === TxTypes.TransferFromSavings)
            return op_type_map.map.transfer_from_savings
        else if (tx_type === TxTypes.HbdInterest)
            return op_type_map.map.interest
        else if (tx_type === TxTypes.FillTransferFromSavings)
            return op_type_map.map.fill_transfer_from_savings
        else
            return -1
    }
}

export default op_type_map