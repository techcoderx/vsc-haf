import db from './db.js'
import logger from './logger.js'
import { TxTypes } from './processor_types.js'
import { CUSTOM_JSON_IDS } from './constants.js'

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
        let op_types = await db.client.query('SELECT * FROM vsc_app.l1_operation_types;')
        for (let i in op_types.rows)
            op_type_map.map[op_types.rows[i].op_name] = op_types.rows[i].id
        logger.debug('Loaded op_type -> id mapping, count: '+op_types.rowCount)
        logger.trace(op_type_map.map)
    },
    translate: (tx_type: TxTypes, idx: number = -1): number => {
        if (tx_type === TxTypes.AccountUpdate)
            return op_type_map.map.announce_node
        else if (tx_type === TxTypes.CustomJSON)
            return op_type_map.map[CUSTOM_JSON_IDS[idx].split('.')[1]]
        else
            return -1
    }
}

export default op_type_map