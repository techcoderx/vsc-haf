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
