export const DB_VERSION = 1
export const APP_CONTEXT = 'vsc_app'
export const SCHEMA_NAME = 'vsc_app'
export const CUSTOM_JSON_IDS = [
    'vsc.enable_witness',
    'vsc.disable_witness',
    'vsc.allow_witness',
    'vsc.disallow_witness',
    'vsc.announce_block',
    'vsc.create_contract',
    'vsc.join_contract',
    'vsc.leave_contract',
    'vsc.multisig_txref',
    'vsc.custom_json',
    'vsc.withdraw_request'
]
export const XFER_ACTIONS = [
    'deposit',
    'withdrawal'
]
export const L1_ASSETS = [
    '@@000000021', // HIVE
    '@@000000013', // HBD
]
export const START_BLOCK = 74869131
export const NETWORK_ID = 'testnet/d12e6110-9c8c-4498-88f8-67ddf90d451c'
export const MULTISIG_ACCOUNT = 'vsc.ptk-d12e6110'