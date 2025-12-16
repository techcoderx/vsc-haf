export const DB_VERSION = 1
export const APP_CONTEXT = 'vsc_mainnet'
export const SCHEMA_NAME = 'vsc_mainnet'
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
export const START_BLOCK = 94601000
export const NETWORK_ID = 'vsc-mainnet'
export const NETWORK_ID_ANNOUNCE = 'go-mainnet'
export const MULTISIG_ACCOUNT = 'vsc.gateway'
export const DAO_ACCOUNT = 'vsc.dao'
