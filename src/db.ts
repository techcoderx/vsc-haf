import pg from 'pg'
import config from './config.js'
import logger from './logger.js'

const client = new pg.Client({ connectionString: config.postgres_url })

const db = {
    init: async () => {
        await db.client.connect()
        logger.info('Connected to database',config.postgres_url)
    },
    disconnect: async () => {
        await db.client.end()
        logger.info('Disconnected from database')
    },
    restart: async () => {
        await db.client.end()
        db.client = new pg.Client({ connectionString: config.postgres_url })
        await db.client.connect()
    },
    client: client
}

export default db