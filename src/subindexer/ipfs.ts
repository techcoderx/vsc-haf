import { create } from 'kubo-rpc-client'
import config from '../config.js'
import logger from '../logger.js'

const ipfs = create({
    url: config.ipfsApiUrl,
    timeout: 30000
})

const ipfsId = await ipfs.id()
logger.info('Connected to IPFS node',ipfsId.id.toString())

export default ipfs