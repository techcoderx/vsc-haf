import * as Block from 'multiformats/block'
import * as codec from '@ipld/dag-cbor'
import { sha256 as hasher } from 'multiformats/hashes/sha2'

export const createDag = async (value: any) => {
   return (await Block.encode({ value, codec, hasher })).cid
}
