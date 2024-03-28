import { WitnessConsensusDid } from './psql_types.js'

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

export type PayloadTypes = NewContractPayload | NodeAnnouncePayload | ElectionPayload | MultisigTxRefPayload | DepositPayload

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

export type CustomJsonPayloads = BlockOp | ElectionOp | BridgeRefPayload | L1CallTxOp
export type BridgeRefResult = bigint[]
export type L2PayloadTypes = BridgeRefResult | ElectionPayload | BlockPayload | L1TxPayload
export interface BlockOp {
    net_id: string
    replay_id: number
    signed_block: SignedBlock<string>
}

export type BlockPayload = {
    block_hash: string
    block_header_cid: string
    br: [number, number]
    merkle_root: Buffer
    signature: BLSAggSign<Buffer>
}

export interface UnsignedBlock<BlockCIDType> {
    block: BlockCIDType
    headers: {
        br: [number, number],
        prevb: string
    },
    merkle_root: string
    signature?: BLSAggSign<string>
}

export interface SignedBlock<T> extends UnsignedBlock<T> {
    signature: BLSAggSign<string>
}

export interface ElectionOp extends UnsignedElection {
    signature: BLSAggSign<string>
}

export interface ElectionMember<T> {
    account: T
    key: string
}

export interface ShuffledSchedule extends WitnessConsensusDid {
    bn: number
    bn_works: boolean
    in_past: boolean
}

export interface L1CallTxOp {
    tx: {
        op: 'call_contract'
        action: string
        payload: any
        contract_id: string
    }
}

export interface L1TxPayload {
    callers: {
        user: string
        auth: 1 | 2
    }[]
    contract_id: string
    action: string
    payload: any
}