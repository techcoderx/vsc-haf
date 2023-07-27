export type ParsedOp = {
    valid: boolean
    id?: string // pg library returns strings for bigint type
    ts?: Date
    user?: string
    block_num?: number
    tx_type?: TxTypes
    op_type?: number
    payload?: DIDPayload | BlockPayload | NewContractPayload | ContractCommitmentPayload | NodeAnnouncePayload | MultisigTxRefPayload
}

export enum TxTypes {
    CustomJSON,
    AccountUpdate
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
}

export type MultisigTxRefPayload = {
    ref_id: string
}