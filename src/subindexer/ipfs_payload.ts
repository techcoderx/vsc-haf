export interface BridgeRef {
    withdrawals: {
        amount: number,
        dest: string,
        id: string,
        unit: 'HIVE' | 'HBD'
    }[]
}

interface ContractCallHead {
    id: string
    op: string
    type: 1
}

interface ContractOutHead {
    contract_id: string
    id: string
    type: 2
}

type BlockBodyTx = ContractCallHead | ContractOutHead | AnchorRefHead

export interface BlockBody {
    __t: 'vsc-block'
    __v: '0.1'
    headers: {
        prevb?: string
    },
    merkle_root: string
    sig_root?: string
    txs: BlockBodyTx[]
}

export interface ContractCallBody {
    __t: 'vsc-tx'
    __v: '0.2'
    headers: {
        nonce: number
        required_auths: string[]
        type: 1
    }
    tx: {
        action: string
        contract_id: string
        op: 'call_contract'
        payload: any
    }
}

export interface ContractOutBody {
    __t: 'vsc-output'
    __v: '0.1'
    contract_id: string
    inputs: string[]
    io_gas: number
    results: any[]
    state_merkle: string
}

export interface AnchorRefHead {
    chain: 'hive'
    data: string
    id: string
    type: 5
}

export interface AnchorRefBody {
    txs: Uint8Array[]
}

export interface AnchorRefPayload extends AnchorRefHead {
    index: number
    txs: string[]
}