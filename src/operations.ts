import db from './db.js'
import logger from './logger.js'
import { TxTypes } from './processor_types.js'
import { CUSTOM_JSON_IDS, SCHEMA_NAME, XFER_ACTIONS } from './constants.js'

type OpTypeIDMap = {
    [key: string]: number
}

type OpTypeMod = {
    map: OpTypeIDMap
    retrieveMap: () => Promise<void>,
    translate: (tx_type: TxTypes, idx: number) => number
}

// op_type -> id mapping
const op_type_map: OpTypeMod = {
    map: {},
    retrieveMap: async (): Promise<void> => {
        let op_types = await db.client.query(`SELECT * FROM ${SCHEMA_NAME}.l1_operation_types;`)
        for (let i in op_types.rows)
            op_type_map.map[op_types.rows[i].op_name] = op_types.rows[i].id
        logger.debug('Loaded op_type -> id mapping, count: '+op_types.rowCount)
        logger.trace(op_type_map.map)
    },
    translate: (tx_type: TxTypes, idx: number = -1): number => {
        if (tx_type === TxTypes.AccountUpdate)
            return op_type_map.map.announce_node
        else if (tx_type === TxTypes.CustomJSON) {
            let cjtype = CUSTOM_JSON_IDS[idx].split('.')[1]
            if (cjtype === 'announce_tx')
                cjtype = 'tx'
            return op_type_map.map[cjtype]
        } else if (tx_type === TxTypes.Transfer)
            return op_type_map.map[XFER_ACTIONS[idx]]
        else
            return -1
    }
}

export default op_type_map