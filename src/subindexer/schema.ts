import * as fs from 'fs'
import { dirname } from 'path'
import { fileURLToPath } from 'url'
import db from '../db.js'
import logger from '../logger.js'
import { SCHEMA_NAME, APP_CONTEXT } from '../constants.js'
import { FKS_TYPE, INDEXES_TYPE, Ordering } from '../schema_types.js'

const __dirname = dirname(fileURLToPath(import.meta.url))

// FK name: FKS_TYPE
export const HAF_FKS: FKS_TYPE = {
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
    election_proposed_in_op_fk: {
        table: SCHEMA_NAME+'.election_results',
        fk: 'proposed_in_op',
        ref: SCHEMA_NAME+'.l1_operations(id)'
    },
    election_proposer_fk: {
        table: SCHEMA_NAME+'.election_results',
        fk: 'proposer',
        ref: `hive.${APP_CONTEXT}_accounts(id)`
    },
    elected_members_epoch_fk: {
        table: SCHEMA_NAME+'.election_result_members',
        fk: 'epoch',
        ref: SCHEMA_NAME+'.election_results(epoch)'
    },
    elected_members_user_id_fk: {
        table: SCHEMA_NAME+'.election_result_members',
        fk: 'witness_id',
        ref: `hive.${APP_CONTEXT}_accounts(id)`
    },
    l1_txs_op_id_fk: {
        table: SCHEMA_NAME+'.l1_txs',
        fk: 'id',
        ref: SCHEMA_NAME+'.l1_operations(id)'
    },
    l1_txs_details_fk: {
        table: SCHEMA_NAME+'.l1_txs',
        fk: 'details',
        ref: SCHEMA_NAME+'.transactions(id)'
    },
    l1_tx_multiauth_tx_id: {
        table: SCHEMA_NAME+'.l1_tx_multiauth',
        fk: 'id',
        ref: SCHEMA_NAME+'.l1_txs(id)'
    },
    l1_tx_multiauth_user_id_fk: {
        table: SCHEMA_NAME+'.l1_tx_multiauth',
        fk: 'user_id',
        ref: `hive.${APP_CONTEXT}_accounts(id)`
    },
    l2_txs_block_num_fk: {
        table: SCHEMA_NAME+'.l2_txs',
        fk: 'block_num',
        ref: SCHEMA_NAME+'.blocks(id)'
    },
    l2_txs_details_fk: {
        table: SCHEMA_NAME+'.l2_txs',
        fk: 'details',
        ref: SCHEMA_NAME+'.transactions(id)'
    },
    l2_tx_multiauth_tx_id: {
        table: SCHEMA_NAME+'.l2_tx_multiauth',
        fk: 'id',
        ref: SCHEMA_NAME+'.l2_txs(id)'
    },
    l2_tx_multiauth_did_fk: {
        table: SCHEMA_NAME+'.l2_tx_multiauth',
        fk: 'did',
        ref: SCHEMA_NAME+'.dids(id)'
    },
    contract_call_contract_id_fk: {
        table: SCHEMA_NAME+'.transactions',
        fk: 'contract_id',
        ref: SCHEMA_NAME+'.contracts(contract_id)'
    },
    anchor_refs_block_num_fk: {
        table: SCHEMA_NAME+'.anchor_refs',
        fk: 'block_num',
        ref: SCHEMA_NAME+'.blocks(id)'
    },
    anchor_ref_txs_ref_id_fk: {
        table: SCHEMA_NAME+'.anchor_ref_txs',
        fk: 'ref_id',
        ref: SCHEMA_NAME+'.anchor_refs(id)'
    }
}

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