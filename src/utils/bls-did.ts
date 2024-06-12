// https://github.com/vsc-eco/vsc-node/blob/main/src/services/new/utils/crypto/bls-did.ts
import bls, { init } from '@chainsafe/bls/switchable'
import type { PublicKey, Signature } from '@chainsafe/bls/types'
import BitSet from 'bitset'
import { decode } from 'codeco'
import { uint8ArrayAsBase64pad } from '@didtools/codecs'
import * as u8a from 'uint8arrays'
import { parse } from 'did-resolver'

export function decodeBase64(s: string) {
  return decode(uint8ArrayAsBase64pad, s);
}

/**
 * Light(er) implementation of BLS DIDs
 * Not standard compliant
 * G1 BLS curves
 */
export class BlsDID {
  pubKey: PublicKey

  constructor({ pubKey }: { pubKey: PublicKey }) {
    this.pubKey = pubKey
  }

  get id() {
    const publicKey = this.pubKey.toBytes()
    const bytes = new Uint8Array(publicKey.length + 2)
    bytes[0] = 0xea // ed25519 multicodec
    // The multicodec is encoded as a varint so we need to add this.
    // See js-multicodec for a general implementation
    bytes[1] = 0x01
    bytes.set(publicKey, 2)
    return `did:key:z${u8a.toString(bytes, 'base58btc')}`
  }

  async verify({ msg, sig }: { msg: any, sig: any }) {
    let signature: Signature
    if (typeof sig === 'string') {
      signature = bls.Signature.fromBytes(decodeBase64(sig))
    } else {
      signature = bls.Signature.fromBytes(sig)
    }
    if (typeof sig === 'string') {
      msg = decodeBase64(sig)
    } else {
      msg = msg
    }
    return signature.verify(this.pubKey, msg)
  }

  static fromString(did: string) {
    const parseDid = parse(did)
    const pubKey = u8a.fromString(parseDid!.id.slice(1), 'base58btc').slice(2)

    return new BlsDID({
      pubKey: bls.PublicKey.fromBytes(pubKey),
    })
  }
}

/**
 * Aggregated bls signatures with mapping
 */
export class BlsCircuit {
  did?: BlsDID
  sig?: Signature
  msg: {
    data: Uint8Array
    hash: Uint8Array
  }
  aggPubKeys: Map<string, boolean>
  // bitSet: BitSet
  constructor(msg: any) {
    this.msg = msg

    this.aggPubKeys = new Map()
  }

  async verify(msg: any) {
    return this.sig!.verify(
      this.did!.pubKey,
      msg,
    )
  }

  setAgg(pubKeys: Array<string>) {
    let aggPub = bls.PublicKey.aggregate(
      pubKeys.map((e) => {
        return BlsDID.fromString(e).pubKey
      }),
    )
    const did = new BlsDID({
      pubKey: aggPub,
    })
    this.did = did;
  }

  static deserialize(signedPayload: any, keyset: Array<string>) {
    const signature = signedPayload.signature
    delete signedPayload.signature

    return BlsCircuit.deserializeRaw(signedPayload,
      Buffer.from(signature.sig as string, 'base64url'),
      Buffer.from(signature.bv as string, 'base64url'),
      keyset
    )
  }

  static deserializeRaw(msg: any, signature: Buffer, bv: string | Buffer, keyset: Array<string>, weights?: number[]) {
    if (weights && weights.length !== keyset.length)
      throw new Error('weights must have the same array length as keyset')
    if (typeof bv !== 'string')
      bv = bv.toString('hex')

    const bs = BitSet.fromHexString(bv)
    const pubKeys = new Map();
    const pubKeyArray: string[] = []
    let totalWeight = 0
    let votedWeight = 0
    for(let keyIdx in keyset) {
      if(bs.get(Number(keyIdx)) === 1) {
        pubKeys.set(keyset[keyIdx], true)
        pubKeyArray.push(keyset[keyIdx])
        if (weights)
          votedWeight += weights[keyIdx]
      }
      if (weights)
        totalWeight += weights[keyIdx]
    }

    let circuit = new BlsCircuit(msg);
    circuit.aggPubKeys = pubKeys
    circuit.setAgg(pubKeyArray)
    circuit.sig = bls.Signature.fromBytes(signature)

    return {
      pubKeys: pubKeyArray,
      totalWeight,
      votedWeight,
      circuit,
      bs
    }
  }
}

void (async () => {
  await init('blst-native')
})()

export async function initBls() {
  await init('blst-native')
}