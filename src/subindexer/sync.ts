import logger from '../logger.js'
import db from '../db.js'
import schema, { HAF_FKS, INDEXES } from './schema.js'
import parentSchema from '../schema.js'
import op_type_map from '../operations.js'
import processor from './processor.js'
import { SCHEMA_NAME } from '../constants.js'

const sync = {
    terminating: false,
    prebegin: async () => {
        // update functions and load operations map
        await schema.createFx()
        await op_type_map.retrieveMap()

        sync.begin()
    },
    begin: async (): Promise<void> => {
        if (sync.terminating)
            return sync.close()

        let shouldMassiveSync = await db.client.query(`SELECT ${SCHEMA_NAME}.subindexer_should_massive_sync();`)
        if (shouldMassiveSync.rows[0].subindexer_should_massive_sync)
            sync.sync(true)
        else
            sync.postMassive()
    },
    sync: async (isMassive = false): Promise<void> => {
        if (sync.terminating)
            return sync.close()

        await db.client.query('START TRANSACTION;')
        let next_ops = await db.client.query(`SELECT ${SCHEMA_NAME}.subindexer_next_ops(true);`)
        let first_op = next_ops.rows[0].first_op
        let last_op = next_ops.rows[0].last_op
        logger.debug('Next ops: ['+first_op+','+last_op+']')
        if (first_op === null) {
            await db.client.query('COMMIT;')
            if (isMassive)
                sync.postMassive()
            else
                setTimeout(() => sync.sync(false), 3000)
            return
        }

        let start = new Date().getTime()
        let ops = await db.client.query(`SELECT * FROM ${SCHEMA_NAME}.enum_vsc_op($1,$2);`,[first_op,last_op])
        let count = 0
        for (let op in ops.rows) {
            let processed = await processor.process(ops.rows[op])
            if (processed)
                count++
        }
        await db.client.query(`SELECT ${SCHEMA_NAME}.subindexer_update_last_processed($1);`,[last_op])
        await db.client.query('COMMIT;')
        let timeTaken = (new Date().getTime()-start)
        logger.info('Subindexer - Op #'+first_op+' to #'+last_op+' - '+count+' ops - '+timeTaken+'ms ('+(count/timeTaken).toFixed(3)+'op/s)')
        sync.sync(isMassive)
    },
    postMassive: async () => {
        await parentSchema.indexCreate(INDEXES)
        await parentSchema.fkCreate(HAF_FKS)
        sync.sync(false)
    },
    close: async () => {
        await db.disconnect()
        process.exit(0)
    }
}

export default sync