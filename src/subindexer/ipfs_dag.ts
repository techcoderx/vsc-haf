import * as Block from 'multiformats/block'
import { CID } from 'multiformats/cid'
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

export const isCID = (hash: CID | Uint8Array | string): hash is CID => {
   try {
      if (typeof hash === 'string')
         return Boolean(CID.parse(hash))
      else if (hash instanceof Uint8Array)
         return Boolean(CID.decode(hash))
      else
         return Boolean(CID.asCID(hash)) // eslint-disable-line no-new
   } catch {
     return false
   }
}