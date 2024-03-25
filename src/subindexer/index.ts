import logger from '../logger.js'
import db from '../db.js'
import schema from './schema.js'
import sync from './sync.js'

await db.init()

if (!(await schema.loaded())) {
    logger.fatal('Schema is not loaded yet. Please start the main HAF sync process first.')
    await db.disconnect()
    process.exit(1)
} else
    await schema.setup()

const handleExit = async () => {
    if (sync.terminating) return
    sync.terminating = true
    process.stdout.write('\r')
    logger.info('Received SIGINT')
}

process.on('SIGINT', handleExit)
process.on('SIGTERM', handleExit)

sync.begin()