export type Op = {
    id: string
    block_num: number
    trx_in_block: number
    op_pos: number
    timestamp: Date
    body: string
}

export type PayloadTypes = BlockPayload | NewContractPayload | NodeAnnouncePayload | MultisigTxRefPayload | DepositPayload

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
    signature: BLSAggSign
}

export type ElectionPayload = {
    data: string
    epoch: number
    signature: BLSAggSign
}

export type NewContractPayload = {
    contract_id: string
    name?: string
    description?: string
    code: string
}

export type ContractCommitmentPayload = {
    contract_id: string
    node_identity: string
}

export type NodeAnnouncePayload = {
    did: string
    consensusDid: string
    witnessEnabled: boolean
    git_commit: string
}

export type MultisigTxRefPayload = {
    ref_id: string
}

export type DepositPayload = {
    amount: number
    asset: number
    contract_id?: string
}

export type BLSAggSign = {
    sig: string,
    bv: string
}