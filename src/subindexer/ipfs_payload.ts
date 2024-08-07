export type Coin = 'HIVE' | 'HBD'

export interface BridgeRef {
    withdrawals: {
        amount: number,
        dest: string,
        id: string,
        unit: Coin
    }[]
}

export type InputType = 'call_contract' | 'transfer' | 'withdraw'

interface ContractCallHead {
    id: string
    op: InputType
    type: 1
}

interface ContractOutHead {
    contract_id: string
    id: string
    type: 2
}

interface EventsOutHead {
    id: string
    type: 6
}

type BlockBodyTx = ContractCallHead | ContractOutHead | AnchorRefHead | EventsOutHead

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

interface InputBodyBase {
    __t: 'vsc-tx'
    __v: '0.2'
    headers: {
        nonce: number
        required_auths: string[]
        type: number
        payer?: string
        lock_block?: string
        intents?: null | string[]
    }
    tx: {
        op: InputType
        payload: any
    }
}

export interface ContractCallBody extends InputBodyBase {
    tx: {
        action?: string
        contract_id?: string
        op: 'call_contract'
        payload: any
    }
}

export interface TransferBody extends InputBodyBase {
    tx: {
        op: 'transfer'
        payload: {
            amount: number,
            from: string,
            memo?: string,
            tk: Coin,
            to: string
        }
    }
}

export interface WithdrawBody extends InputBodyBase {
    tx: {
        op: 'withdraw',
        payload: {
            amount: number,
            from: string,
            memo?: string,
            tk: Coin,
            to: string
        }
    }
}

export type InputBody = ContractCallBody | TransferBody | WithdrawBody

export interface ContractOutBody {
    __t: 'vsc-output'
    __v: '0.1'
    contract_id: string
    inputs: string[]
    io_gas: number
    results: any[]
    state_merkle: string
}

export enum EventOpType {
    'ledger:transfer' = 110_001,
    'ledger:withdraw' = 110_002,
    'ledger:deposit' = 110_003,
  
    //Reserved for future, DO NOT USE
    'ledger:stake_hbd' = 110_004,
    'ledger:unstake_hbd' = 110_005,
    'ledger:claim_hbd' = 110_006,
    
    //Reserved for future, DO NOT USE
    'consensus:stake' = 100_001,
    'consensus:unstake' = 100_002
}

export interface EventOp {
    owner: string
    tk: Coin
    t: EventOpType
    amt: number
    memo?: string
}

export interface EventOutBody {
    __t: 'vsc-events'
    txs: Array<string>
    txs_map: Array<Array<number>>
    events: Array<EventOp>
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

export interface ContractStorageProof {
    cid: string
    type: 'data-availability'
}