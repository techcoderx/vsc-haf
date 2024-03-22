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
export const NETWORK_ID = 'testnet/0bf2e474-6b9e-4165-ad4e-a0d78968d20c'
export const MULTISIG_ACCOUNT = 'vsc.ms-8968d20c'
