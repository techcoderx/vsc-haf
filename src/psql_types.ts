/* HAF function return types */
export type AppNextBlock = {
    first_block?: number
    last_block?: number
}

export type L1OpTypes = {
    id: number
    op_name: string
    filterer: bigint
}

/* Mainly subindexer types below this point */
export type SubindexerNextOps = {
    first_op?: number
    last_op?: number
}

export type BlockScheduleParams = {
    rnd_length: number
    total_rnds: number
    mod_length: number
    mod3: number
    past_rnd_height: number
    next_rnd_height: number
    block_id: string
    epoch: number
}

export type WitnessConsensusDid = {
    name: string
    consensus_did: string
}