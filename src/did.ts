import { DID } from 'dids'
import { Ed25519Provider } from 'key-did-provider-ed25519'
import KeyResolver from 'key-did-resolver'
import randomBytes from 'randombytes'

let pk = randomBytes(32)
let prov = new Ed25519Provider(pk)
let randomDID = new DID({ provider: prov, resolver: KeyResolver.getResolver() })
await randomDID.authenticate()

export default randomDID