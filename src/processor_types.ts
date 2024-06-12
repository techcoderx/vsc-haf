import { AnchorRefPayload } from './subindexer/ipfs_payload.js'
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

export type PayloadTypes = NodeAnnouncePayload | ElectionPayload | MultisigTxRefPayload | DepositPayload

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
}

export interface ElectionPayload2 extends ElectionPayload {
    members: ElectionMemberWeighted<number>[]
    voted_weight: number
    weight_total: number
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

export type CustomJsonPayloads = BlockOp | NewContractOp | ElectionOp | BridgeRefPayload | L1CallTxOp
export type BridgeRefResult = bigint[]
export type L2PayloadTypes = BridgeRefResult | ElectionPayload2 | BlockPayload | L1TxPayload | NewContractPayload
export type L2Tx = L2ContractCallPayload | L2ContractOutPayload | AnchorRefPayload
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
    txs: L2Tx[]
    voted_weight: number
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

export interface ContractCallPayload {
    contract_id: string
    action: string
    payload: any
}

export interface L2TxPayload {
    id: string
    type: number
    index: number
}

export interface L2ContractCallPayload extends ContractCallPayload, L2TxPayload {
    type: 1
    callers: string[]
    nonce: number
}

export interface L2ContractOutPayload extends L2TxPayload {
    type: 2
    inputs: string[]
    contract_id: string
    io_gas: number
    results: any[]
}

export interface ElectionOp extends UnsignedElection {
    signature: BLSAggSign<string>
}

export interface ElectionMember<T> {
    account: T
    key: string
}

export interface ElectionMemberWeighted<T> extends ElectionMember<T> {
    weight: number
}

export interface ShuffledSchedule extends WitnessConsensusDid {
    bn: number
    bn_works: boolean
    in_past: boolean
}

export interface NewContract {
    name?: string
    description?: string
    code: string
}

export interface NewContractOp extends NewContract {
    net_id: string
    storage_proof?: {
        hash: string
        signature: BLSAggSign<string>
    }
}

export interface NewContractPayload extends NewContract {
    contract_id: string
    storage_proof?: {
        hash: string
        signature: BLSAggSign<Buffer>
    }
}

export interface L1CallTxOp {
    tx: {
        op: 'call_contract'
        action: string
        payload: any
        contract_id: string
    }
}

export interface L1TxPayload extends ContractCallPayload {
    callers: {
        user: string
        auth: 1 | 2
    }[]
}