import * as Block from 'multiformats/block'
import * as codec from '@ipld/dag-cbor'
import { sha256 as hasher } from 'multiformats/hashes/sha2'

export const createDag = async (value: any) => {
   return (await Block.encode({ value, codec, hasher })).cid
}

export const encodePayload = async (payload: any) => {
   const block = await Block.encode({
      value: payload,
      codec: codec,
      hasher: hasher
   })
   return {
      cid: block.cid,
      linkedBlock: block.bytes
   }
}