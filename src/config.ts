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
        },
        logFile: {
            type: 'string',
            default: './logs/output.log'
        },
        ipfsApiUrl: {
            type: 'string',
            default: 'http://localhost:5001'
        }
    })
    .parseSync()

export default config