export type Op = {
    id: string
    block_num: number
    body: string
}

export type ParsedOp = {
    valid: boolean
    id?: string // pg library returns strings for bigint type
    ts?: Date
    user?: string
    block_num?: number
    tx_type?: TxTypes
    op_type?: number
    payload?: DIDPayload | BlockPayload | NewContractPayload | ContractCommitmentPayload | NodeAnnouncePayload | MultisigTxRefPayload | DepositPayload
}

export enum TxTypes {
    CustomJSON,
    AccountUpdate,
    Transfer
}

export type DIDPayload = {
    did: string
}

export type BlockPayload = {
    block_hash: string
}

export type NewContractPayload = {
    manifest_id: string
    name: string // pla: obsolete as its already contained in the manifest, correct?
    code: string
}

export type ContractCommitmentPayload = {
    contract_id: string
    node_identity: string
}

export type NodeAnnouncePayload = {
    did: string
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