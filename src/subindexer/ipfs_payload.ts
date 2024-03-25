export interface BridgeRef {
    withdrawals: {
        amount: number,
        dest: string,
        id: string,
        unit: 'HIVE' | 'HBD'
    }[]
}