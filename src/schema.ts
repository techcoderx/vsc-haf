import * as fs from 'fs'
import { dirname } from 'path'
import { fileURLToPath } from 'url'
import { START_BLOCK, DB_VERSION, APP_CONTEXT, SCHEMA_NAME, CUSTOM_JSON_IDS, CUSTOM_JSON_ALIAS } from './constants.js'
import db from './db.js'
import context from './context.js'
import logger from './logger.js'
import { FKS_TYPE, INDEXES_TYPE, Ordering } from './schema_types.js'

const __dirname = dirname(fileURLToPath(import.meta.url))

// tables to be registered for forking HAF app
const HAF_TABLES: string[] = []

// FK name: FKS_TYPE
const HAF_FKS: FKS_TYPE = {
    l1_op_user_id_fk: {
        table: SCHEMA_NAME+'.l1_operations',
        fk: 'user_id',
        ref: `hive.${APP_CONTEXT}_accounts(id)`
    },
    l1_op_type_fk: {
        table: SCHEMA_NAME+'.l1_operations',
        fk: 'op_type',
        ref: SCHEMA_NAME+'.l1_operation_types(id)'
    },
    l1_users_fk: {
        table: SCHEMA_NAME+'.l1_users',
        fk: 'id',
        ref: `hive.${APP_CONTEXT}_accounts(id)`
    },
    block_proposed_in_op_fk: {
        table: SCHEMA_NAME+'.blocks',
        fk: 'proposed_in_op',
        ref: SCHEMA_NAME+'.l1_operations(id)'
    },
    block_proposer_fk: {
        table: SCHEMA_NAME+'.blocks',
        fk: 'proposer',
        ref: `hive.${APP_CONTEXT}_accounts(id)`
    },
    contract_created_in_op_fk: {
        table: SCHEMA_NAME+'.contracts',
        fk: 'created_in_op',
        ref: SCHEMA_NAME+'.l1_operations(id)'
    },
    witness_account_fk: {
        table: SCHEMA_NAME+'.witnesses',
        fk: 'id',
        ref: `hive.${APP_CONTEXT}_accounts(id)`
    },
    witness_enabled_at_fk: {
        table: SCHEMA_NAME+'.witnesses',
        fk: 'enabled_at',
        ref: SCHEMA_NAME+'.l1_operations(id)'
    },
    witness_disabled_at_fk: {
        table: SCHEMA_NAME+'.witnesses',
        fk: 'disabled_at',
        ref: SCHEMA_NAME+'.l1_operations(id)'
    },
    witness_toggle_wid_fk: {
        table: SCHEMA_NAME+'.witness_toggle_archive',
        fk: 'witness_id',
        ref: `hive.${APP_CONTEXT}_accounts(id)`
    },
    witness_toggle_op_id_fk: {
        table: SCHEMA_NAME+'.witness_toggle_archive',
        fk: 'op_id',
        ref: SCHEMA_NAME+'.l1_operations(id)'
    },
    keyauths_uid_fk: {
        table: SCHEMA_NAME+'.keyauths_archive',
        fk: 'user_id',
        ref: `hive.${APP_CONTEXT}_accounts(id)`
    },
    keyauths_op_id_fk: {
        table: SCHEMA_NAME+'.keyauths_archive',
        fk: 'op_id',
        ref: SCHEMA_NAME+'.l1_operations(id)'
    },
    multisig_txref_in_op_fk: {
        table: SCHEMA_NAME+'.multisig_txrefs',
        fk: 'in_op',
        ref: SCHEMA_NAME+'.l1_operations(id)'
    }
}

// Indexes
const INDEXES: INDEXES_TYPE = {
    l1_operation_type_idx: {
        table_name: SCHEMA_NAME+'.l1_operation_types',
        columns: [{ col_name: 'op_name', order: Ordering.ASC }]
    },
    l1_operation_id_idx: {
        table_name: SCHEMA_NAME+'.l1_operations',
        columns: [{ col_name: 'op_id', order: Ordering.ASC }]
    },
    l1_operation_user_nonce_idx: {
        table_name: SCHEMA_NAME+'.l1_operations',
        columns: [{ col_name: 'user_id', order: Ordering.ASC }, { col_name: 'nonce', order: Ordering.DESC }]
    },
    l1_operation_user_txtype_idx: {
        table_name: SCHEMA_NAME+'.l1_operations',
        columns: [{ col_name: 'user_id', order: Ordering.ASC }, { col_name: 'op_type', order: Ordering.ASC }]
    },
    block_hash_idx: {
        table_name: SCHEMA_NAME+'.blocks',
        columns: [{ col_name: 'block_hash', order: Ordering.ASC }]
    },
    contract_created_in_op_idx: {
        table_name: SCHEMA_NAME+'.contracts',
        columns: [{ col_name: 'created_in_op', order: Ordering.DESC }]
    },
    witness_did_idx: {
        table_name: SCHEMA_NAME+'.witnesses',
        columns: [{ col_name: 'did', order: Ordering.ASC }]
    },
    witness_toggle_archive_witness_id_op_id_idx: {
        table_name: SCHEMA_NAME+'.witness_toggle_archive',
        columns: [{ col_name: 'witness_id', order: Ordering.ASC }, { col_name: 'op_id', order: Ordering.DESC }]
    },
    keyauths_archive_witness_id_op_id_idx: {
        table_name: SCHEMA_NAME+'.keyauths_archive',
        columns: [{ col_name: 'user_id', order: Ordering.ASC }, { col_name: 'op_id', order: Ordering.DESC }]
    },
    txref_in_op_idx: {
        table_name: SCHEMA_NAME+'.multisig_txrefs',
        columns: [{ col_name: 'in_op', order: Ordering.ASC }]
    }
}

const schema = {
    setup: async () => {
        logger.info('Setting up HAF app database...')
        await db.client.query(`CREATE SCHEMA IF NOT EXISTS ${SCHEMA_NAME};`)

        // setup app context
        let ctxExists = await context.exists()
        if (!ctxExists)
            await context.create()
        
        // setup app tables
        await db.client.query(fs.readFileSync(__dirname+'/sql/create_tables.sql','utf-8'))

        // inheritance for forking app
        for (let t in HAF_TABLES)
            await db.client.query(`ALTER TABLE ${SCHEMA_NAME}.${HAF_TABLES[t]} INHERIT hive.${SCHEMA_NAME};`)

        // use 'accounts' state provider
        await db.client.query(`SELECT hive.app_state_provider_import('ACCOUNTS',$1);`,[APP_CONTEXT])
        logger.info('Imported accounts state provider')

        // detach app context
        await context.detach()

        // start block
        let startBlock = Math.max(START_BLOCK-1,0)
        await db.client.query('START TRANSACTION;')
        if (startBlock > 0) {
            logger.info('Updating state providers to starting block...')
            let start = new Date().getTime()
            await db.client.query('SELECT hive.app_state_providers_update($1,$2,$3);',[0,startBlock,APP_CONTEXT])
            logger.info('State providers updated in',(new Date().getTime()-start),'ms')
        }
        await db.client.query(`UPDATE ${SCHEMA_NAME}.state SET last_processed_block=$1;`,[startBlock])
        await db.client.query(`SELECT hive.app_set_current_block_num($1,$2);`,[APP_CONTEXT,startBlock])
        await db.client.query('COMMIT;')
        logger.info('Set last processed block to #'+(startBlock))

        // fill with initial values
        await db.client.query(`INSERT INTO ${SCHEMA_NAME}.state(last_processed_block, db_version) VALUES($1, $2);`,[startBlock,DB_VERSION])
        await db.client.query(`INSERT INTO ${SCHEMA_NAME}.l1_operation_types(op_name) VALUES('announce_node');`)
        await db.client.query(`INSERT INTO ${SCHEMA_NAME}.l1_operation_types(op_name) VALUES('rotate_multisig');`)
        for (let c in CUSTOM_JSON_IDS)
            if (typeof CUSTOM_JSON_ALIAS[CUSTOM_JSON_IDS[c]] === 'undefined')
                await db.client.query(`INSERT INTO ${SCHEMA_NAME}.l1_operation_types(op_name) VALUES($1);`,[CUSTOM_JSON_IDS[c].split('.')[1]])
        await db.client.query(`INSERT INTO ${SCHEMA_NAME}.l1_operation_types(op_name) VALUES('deposit');`)
        await db.client.query(`INSERT INTO ${SCHEMA_NAME}.l1_operation_types(op_name) VALUES('withdrawal');`)

        // create relevant functions
        await schema.createFx()

        logger.info('HAF app database set up successfully!')
    },
    loaded: async () => {
        let schemaTbls = await db.client.query('SELECT 1 FROM pg_catalog.pg_tables WHERE schemaname=$1;',[SCHEMA_NAME])
        return schemaTbls.rowCount! > 0
    },
    createFx: async () => {
        await db.client.query(fs.readFileSync(__dirname+'/sql/create_functions.sql','utf-8'))
        await db.client.query(fs.readFileSync(__dirname+'/sql/create_apis.sql','utf-8'))
        logger.info('Created/Updated relevant PL/pgSQL functions and types')
    },
    fkExists: async (fk: string) => {
        let constraint = await db.client.query('SELECT * FROM information_schema.constraint_column_usage WHERE constraint_name=$1',[fk])
        return constraint.rowCount! > 0
    },
    fkCreate: async () => {
        for (let fk in HAF_FKS) {
            logger.info('Creating FK',fk)
            if (await schema.fkExists(fk)) {
                logger.info('FK',fk,'already exists, skipping')
                continue
            }
            let start = new Date().getTime()
            await db.client.query(`ALTER TABLE ${HAF_FKS[fk].table} ADD CONSTRAINT ${fk} FOREIGN KEY(${HAF_FKS[fk].fk}) REFERENCES ${HAF_FKS[fk].ref} DEFERRABLE INITIALLY DEFERRED;`)
            logger.info('FK',fk,'created in',(new Date().getTime()-start),'ms')
        }
    },
    fkDrop: async () => {
        for (let fk in HAF_FKS)
            if (await schema.fkExists(fk)) {
                logger.info('Droping FK',fk)
                let start = new Date().getTime()
                await db.client.query(`ALTER TABLE ${HAF_FKS[fk].table} DROP CONSTRAINT IF EXISTS ${fk};`)
                logger.info('FK',fk,'dropped in',(new Date().getTime()-start),'ms')
            }
    },
    indexExists: async (index_name: string): Promise<boolean> => {
        return (await db.client.query('SELECT * FROM pg_indexes WHERE schemaname=$1 AND indexname=$2',[SCHEMA_NAME, index_name])).rowCount! > 0
    },
    indexCreate: async () => {
        for (let idx in INDEXES) {
            if (await schema.indexExists(idx)) {
                logger.info('Index',idx,'already exists, skipping')
                continue
            }
            let start = new Date().getTime()
            await db.client.query(`CREATE INDEX IF NOT EXISTS ${idx} ON ${INDEXES[idx].table_name}(${INDEXES[idx].columns.map(x => x.col_name+' '+Ordering[x.order]).join(',')}) ${INDEXES[idx].condition?'WHERE '+INDEXES[idx].condition:''};`)
            logger.info('Index',idx,'created in',(new Date().getTime()-start),'ms')
        }
    },
    indexDrop: async () => {
        for (let idx in INDEXES) {
            if (await schema.indexExists(idx)) {
                let start = new Date().getTime()
                await db.client.query(`DROP INDEX IF EXISTS ${idx} CASCADE;`)
                logger.info('Index',idx,'dropped in',(new Date().getTime()-start),'ms')
            }
        }
    }
}

export default schema