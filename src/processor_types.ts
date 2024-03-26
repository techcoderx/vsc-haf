export interface Op {
    id: string
    block_num: number
    trx_in_block: number
    op_pos: number
    timestamp: Date
    body: string
}

export interface OpBody {
    type: 'custom_json_operation' | 'account_update_operation' | 'transfer_operation',
    value: any
}

export type PayloadTypes = BlockPayload | NewContractPayload | NodeAnnouncePayload | ElectionPayload | MultisigTxRefPayload | DepositPayload

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
    Transfer
}

export type BlockPayload = {
    block_hash: string
    signature: BLSAggSign<Buffer>
}

export interface UnsignedElection {
    data: string
    epoch: number
    net_id: string
}

export interface ElectionPayload extends UnsignedElection {
    signature: BLSAggSign<Buffer>
    members?: ElectionMember<number>[]
}

export type NewContractPayload = {
    contract_id: string
    name?: string
    description?: string
    code: string
}

export type NodeAnnouncePayload = {
    did: string
    consensus_did: string
    witnessEnabled: boolean
    git_commit: string
    sk_posting: string
    sk_active: string
    sk_owner: string
}

export type BridgeRefPayload = MultisigTxRefPayload
export type MultisigTxRefPayload = {
    ref_id: string
}

export type DepositPayload = {
    amount: number
    amount2?: number
    asset: number
    owner?: string
}

export type BLSAggSign<T> = {
    sig: T,
    bv: T
}

/* Mainly subindexer types below this point */
export interface VscOp extends Op {
    op_type: number
}

export type CustomJsonPayloads = BlockOp | ElectionOp | BridgeRefPayload
export type BridgeRefResult = bigint[]
export type L2PayloadTypes = BridgeRefResult | ElectionPayload
export interface BlockOp {
    net_id: string
    replay_id: number
    signed_block: {
        block: string
        headers: {
            br: [number, number],
            prevb: string
        },
        signature: BLSAggSign<string>
    }
}

export interface ElectionOp extends UnsignedElection {
    signature: BLSAggSign<string>
}

export interface ElectionMember<T> {
    account: T
    key: string
}