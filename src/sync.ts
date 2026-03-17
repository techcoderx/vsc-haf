import db from './db.js'
import schema from './schema.js'
import context from './context.js'
import logger from './logger.js'
import processor from './processor.js'
import { APP_CONTEXT, SCHEMA_NAME, LIVE_SYNC_CONNECTION_CYCLE_BLKS } from './constants.js'
import op_type_map from './operations.js'
import { EnumBlock, Op } from './processor_types.js'

const LIVE_STAGE = 'LIVE'
const sleep = (ms: number) => new Promise(r => setTimeout(r, ms))

const sync = {
    terminating: false,
    indexesBuilt: false,
    prebegin: async () => {
        await schema.createFx()
        await op_type_map.retrieveMap()
        await sync.loop()
    },
    loop: async (): Promise<void> => {
        while (!sync.terminating) {
            let range = await context.nextIteration()
            if (range.first_block === null || range.last_block === null) {
                await sleep(500)
                continue
            }
            let firstBlock = range.first_block
            let lastBlock = range.last_block
            let stage = await context.currentStage()

            if (stage === LIVE_STAGE && !sync.indexesBuilt) {
                logger.info('Begin post-massive sync')
                await schema.indexCreate()
                await schema.fkCreate()
                logger.info('Post-massive sync complete, entering live sync')
                sync.indexesBuilt = true
            }

            let start = new Date().getTime()
            await db.client.query('SELECT hive.app_state_providers_update($1,$2,$3);',[firstBlock,lastBlock,APP_CONTEXT])
            let blocks = await db.client.query<EnumBlock>(`SELECT * FROM ${SCHEMA_NAME}.enum_block($1,$2);`,[firstBlock,lastBlock])
            let ops = await db.client.query<Op>(`SELECT * FROM ${SCHEMA_NAME}.enum_op($1,$2);`,[firstBlock,lastBlock])
            let count = 0
            for (let op in ops.rows) {
                let processed = await processor.process(ops.rows[op], blocks.rows[ops.rows[op].block_num-firstBlock].created_at)
                if (processed)
                    count++
            }
            await db.client.query(`UPDATE ${SCHEMA_NAME}.state SET last_processed_block=$1;`,[lastBlock])

            let timeTaken = (new Date().getTime()-start)/1000
            if (firstBlock === lastBlock) {
                logger.info(stage+' Sync - Block #'+firstBlock+' - '+count+' ops - '+(timeTaken*1000).toFixed(0)+'ms')
            } else {
                logger.info(stage+' Sync - Block #'+firstBlock+' to #'+lastBlock+' - '+count+' ops - '+((lastBlock-firstBlock+1)/timeTaken).toFixed(3)+'b/s, '+(count/timeTaken).toFixed(3)+'op/s')
            }
        }
        await sync.close()
    },
    close: async (): Promise<void> => {
        await db.disconnect()
        process.exit(0)
    }
}

export default sync