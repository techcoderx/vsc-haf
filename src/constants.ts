export const DB_VERSION = 1
export const APP_CONTEXT = 'vsc_app'
export const SCHEMA_NAME = 'vsc_app'
export const CUSTOM_JSON_IDS = [
    'vsc.propose_block',
    'vsc.create_contract',
    'vsc.announce_tx', // aka vsc.tx
    'vsc.tx',
    'vsc.election_result',
    'vsc.multisig_txref',
    'vsc.bridge_ref'
]
export const CUSTOM_JSON_ALIAS: { [alias: string]: string } = {
    'vsc.announce_tx': 'vsc.tx'
}
export const REQUIRES_ACTIVE = [0,1,4,6]
export const ANY_AUTH = [2,3]
export const XFER_ACTIONS = [
    'deposit',
    'withdrawal',
    'withdrawal_request'
]
export const L1_ASSETS = [
    '@@000000021', // HIVE
    '@@000000013', // HBD
]
export const START_BLOCK = 81614028
export const CONTRACT_DATA_AVAILABLITY_PROOF_REQUIRED_HEIGHT =  84162592
export const NETWORK_ID = 'testnet/0bf2e474-6b9e-4165-ad4e-a0d78968d20c'
export const MULTISIG_ACCOUNT = 'vsc.ms-8968d20c'
export const MULTISIG_ACCOUNT_2 = 'vsc.gateway'
export const ROUND_LENGTH = 10
export const EPOCH_LENGTH = 20 * 60 * 6
export const SUPERMAJORITY = 2/3
export const ELECTION_UPDATE_1_EPOCH = 123
export const ELECTION_UPDATE_2_EPOCH = 125
export const MIN_BLOCKS_SINCE_LAST_ELECTION = 1200 // 1 hour
export const MAX_BLOCKS_SINCE_LAST_ELECTION = 403200 // 2 weeks
