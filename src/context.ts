import { APP_CONTEXT, SCHEMA_NAME, MASSIVE_STAGE_NAME, MASSIVE_SYNC_DISTANCE, MASSIVE_SYNC_BATCH } from './constants.js'
import logger from './logger.js'
import db from './db.js'

export type BlocksRange = {
    first_block: number | null
    last_block: number | null
}

const context = {
    exists: async () => {
        let ctxExists = await db.client.query('SELECT hive.app_context_exists($1);',[APP_CONTEXT])
        return ctxExists.rows[0].app_context_exists
    },
    create: async () => {
        if (await context.exists())
            return logger.info('App context already exists, skipping app context creation')
        await db.client.query(
            `SELECT hive.app_create_context($1, $2, false, true,
                ARRAY[
                    hive.stage($3::hafd.stage_name, $4, $5),
                    hive.live_stage()
                ]::hafd.application_stage[]);`,
            [APP_CONTEXT, SCHEMA_NAME, MASSIVE_STAGE_NAME, MASSIVE_SYNC_DISTANCE, MASSIVE_SYNC_BATCH]
        )
        logger.info('Created app context',APP_CONTEXT,'with stages')
    },
    detach: async () => {
        let isAttached = await db.client.query('SELECT hive.app_context_is_attached($1);',[APP_CONTEXT])
        if (isAttached.rows[0].app_context_is_attached) {
            logger.info('Detaching app context...')
            await db.client.query('SELECT hive.app_context_detach($1);',[APP_CONTEXT])
            logger.info('App context detached successfully')
        } else
            logger.info('App context already detached, skipping')
    },
    nextIteration: async (): Promise<BlocksRange> => {
        let res = await db.client.query<BlocksRange>('CALL ' + SCHEMA_NAME + '.next_iteration(NULL, NULL);')
        return res.rows[0]
    },
    currentStage: async (): Promise<string> => {
        let res = await db.client.query<{ get_current_stage_name: string }>(
            'SELECT hive.get_current_stage_name($1);',[APP_CONTEXT]
        )
        return res.rows[0].get_current_stage_name
    }
}

export default context
