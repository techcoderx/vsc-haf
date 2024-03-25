import * as fs from 'fs'
import { dirname } from 'path'
import { fileURLToPath } from 'url'
import db from '../db.js'
import logger from '../logger.js'
import { SCHEMA_NAME } from '../constants.js'
import { FKS_TYPE, INDEXES_TYPE, Ordering } from '../schema_types.js'

const __dirname = dirname(fileURLToPath(import.meta.url))

// FK name: FKS_TYPE
export const HAF_FKS: FKS_TYPE = {}

// Indexes
export const INDEXES: INDEXES_TYPE = {}

const schema = {
    setup: async () => {
        let alreadySetup = await db.client.query(`SELECT * FROM ${SCHEMA_NAME}.subindexer_state;`)
        if (alreadySetup.rowCount! > 0)
            return

        logger.info('Setting up subindexer db...')
        await db.client.query(`INSERT INTO ${SCHEMA_NAME}.subindexer_state(last_processed_op) VALUES($1);`,[0])
    },
    loaded: async () => {
        let schemaTbls = await db.client.query('SELECT 1 FROM pg_catalog.pg_tables WHERE schemaname=$1 AND tablename=$2;',[SCHEMA_NAME, 'l1_operations'])
        return schemaTbls.rowCount! > 0
    },
    createFx: async () => {
        await db.client.query(fs.readFileSync(__dirname+'/../sql/subindexer.sql','utf-8'))
        logger.info('Created/Updated relevant PL/pgSQL subindexer functions and types')
    }
}

export default schema