export const DB_VERSION = 1
export const APP_CONTEXT = 'magi_app'
export const SCHEMA_NAME = 'magi_app'
export const MASSIVE_STAGE_NAME = 'MASSIVE_SYNC'
export const MASSIVE_SYNC_DISTANCE = 100
export const MASSIVE_SYNC_BATCH = 10000
export const LIVE_SYNC_CONNECTION_CYCLE_BLKS = 1000
export const CUSTOM_JSON_IDS = [
    // issued by MULTISIG_ACCOUNT with active auth only
    'vsc.fr_sync',
    'vsc.actions',

    // system operations
    'vsc.produce_block',
    'vsc.create_contract',
    'vsc.update_contract',
    'vsc.election_result',

    // user operations
    'vsc.withdraw',
    'vsc.call',
    'vsc.transfer',
    'vsc.stake_hbd',
    'vsc.unstake_hbd',
    'vsc.consensus_stake',
    'vsc.consensus_unstake',

    // tss ops
    'vsc.tss_sign',
    'vsc.tss_commitment'
]
export const L1_ASSETS = [
    '@@000000021', // HIVE
    '@@000000013', // HBD
]
export const START_BLOCK = 2
export const NETWORK_ID = 'vsc-testnet'
export const MULTISIG_ACCOUNT = 'vsc.gateway'
export const DAO_ACCOUNT = 'vsc.dao'
