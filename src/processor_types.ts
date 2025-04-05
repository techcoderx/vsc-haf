export interface Op {
    id: string
    block_num: number
    trx_in_block: number
    op_pos: number
    body: string
}

export interface EnumBlock {
    num: number
    created_at: Date
}

export interface OpBody {
    type:
        'custom_json_operation' |
        'account_update_operation' |
        'transfer_operation' |
        'transfer_to_savings_operation' |
        'transfer_from_savings_operation'|
        'interest_operation'|
        'fill_transfer_from_savings_operation'
    value: any
}

export type PayloadTypes = NodeAnnouncePayload

export interface ParsedOp<T> {
    valid: boolean
    id?: string // pg library returns strings for bigint type
    ts?: Date
    user?: string
    block_num?: number
    trx_in_block?: number
    op_pos?: number
    tx_type?: TxTypes
    op_type?: number
    payload?: T
}

export enum TxTypes {
    CustomJSON,
    AccountUpdate,
    Transfer,
    TransferToSavings,
    TransferFromSavings,
    HbdInterest,
    FillTransferFromSavings
}

export type NodeAnnouncePayload = {
    peer_id: string
    peer_addrs: string[]
    version_id: string
    git_commit: string
    protocol_version: number
    gateway_key: string
    witnessEnabled: boolean
    consensus_did: string
}
