export type Op = {
    id: string
    block_num: number
    trx_in_block: number
    op_pos: number
    timestamp: Date
    body: string
}

export type ParsedOp = {
    valid: boolean
    id?: string // pg library returns strings for bigint type
    ts?: Date
    user?: string
    block_num?: number
    trx_in_block?: number
    op_pos?: number
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
    signature: {
        sig: string,
        bv: string
    }
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