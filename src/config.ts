import yargs from 'yargs'
import * as dotenv from 'dotenv'

dotenv.config()
const config = yargs(process.argv)
    .env('VSC_HAF')
    .options({
        postgresUrl: {
            type: 'string',
            default: 'postgres://username:password@127.0.0.1:5432/block_log'
        },
        logLevel: {
            type: 'string',
            default: 'info'
        }
    })
    .parseSync()

export default config