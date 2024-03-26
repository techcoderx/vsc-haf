// https://github.com/vsc-eco/vsc-node/blob/main/src/services/new/utils/crypto/bls-did.ts
import bls, { init } from '@chainsafe/bls/switchable'
import type { PublicKey, Signature } from '@chainsafe/bls/types'
import BitSet from 'bitset'
import { encodePayload } from 'dag-jose-utils'
import { decode } from 'codeco'
import { uint8ArrayAsBase64pad, uint8ArrayAsBase64url } from '@didtools/codecs'
import * as u8a from 'uint8arrays'
import { parse } from 'did-resolver'

export function encodeBase64(bytes: Uint8Array) {
  return uint8ArrayAsBase64pad.encode(bytes);
}
export function encodeBase64Url(bytes: Uint8Array) {
  return uint8ArrayAsBase64url.encode(bytes);
}
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

  add(data: { did: string; sig: string }) {
    return this.addMany([data])
  }

  async addMany(data: Array<{ did: string; sig: string }>): Promise<{ errors: string[] }> {
    let publicKeys = []
    let sigs = []
    let errors = []
    for (let e of data) {
      const did = BlsDID.fromString(e.did)
      let sig = bls.Signature.fromBytes(Buffer.from(e.sig, 'base64url'))

      let msg;
      if(this.msg.hash) {
        msg = this.msg.hash
        console.log('this.msg.hash', this.msg.hash)
      } else {
        msg = (await encodePayload(this.msg.data)).cid.bytes
      }
      if (sig.verify(did.pubKey, msg)) {
        this.aggPubKeys.set(did.id, true)
        publicKeys.push(did.pubKey)
        sigs.push(sig)
      } else {
        errors.push(`INVALID_SIG for ${did.id}`)
        // throw new Error(`INVALID_SIG for ${did.id}`)
      }
    }

    if (this.did) {
      publicKeys.push(this.did.pubKey)
    }
    if (this.sig) {
      sigs.push(this.sig)
    }

    const pubKey = bls.PublicKey.aggregate([...publicKeys])

    const sig = bls.Signature.aggregate([...sigs])

    this.did = new BlsDID({
      pubKey,
    })
    this.sig = sig

    return {
      errors,
    }
  }

  async verify(msg: any) {
    return this.sig!.verify(
      this.did!.pubKey,
      msg,
    )
  }

  async verifySig(data: {sig: string, pub: any}) {
    let msg;
    if(this.msg.hash) {
      msg = this.msg.hash
    } else {
      msg = (await encodePayload(this.msg.data)).cid.bytes
    }
    const did = BlsDID.fromString(data.pub)
    return bls.Signature.fromBytes(Buffer.from(data.sig, 'base64url')).verify(
      did.pubKey,
      msg,
    )
  }

  verifyPubkeys(pubKeys: Array<string>): boolean {
    let aggPub = bls.PublicKey.aggregate(
      pubKeys.map((e) => {
        return BlsDID.fromString(e).pubKey
      }),
    )
    const did = new BlsDID({
      pubKey: aggPub,
    })
    return did.id === this.did!.id
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

  serialize(circuitMap: Array<string>) {
    let bitset = new BitSet()
    for (let str in circuitMap) {
      if (this.aggPubKeys.get(circuitMap[str])) {
        bitset.set(Number(str), 1)
      }
    }
    function d2h(d: any) {
      var h = (d).toString(16);
      return h.length % 2 ? '0' + h : h;
    }
    if(!this.sig) {
      throw new Error('No Valid BLS Signature')
    }
    return {
      sig: Buffer.from(this.sig.toBytes()).toString('base64url'),
      // did: this.did.id,
      //BitVector
      bv: Buffer.from(d2h(bitset.toString(16)), 'hex').toString('base64url'),
    }
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

  static deserializeRaw(msg: any, signature: Buffer, bv: string | Buffer, keyset: Array<string>) {
    if (typeof bv !== 'string')
      bv = bv.toString('hex')

    const bs = BitSet.fromHexString(bv)
    const pubKeys = new Map();
    for(let keyIdx in keyset) {
      if(bs.get(Number(keyIdx)) === 1) {
        pubKeys.set(keyset[keyIdx], true)
      }
    }

    let circuit = new BlsCircuit(msg);
    circuit.aggPubKeys = pubKeys
    circuit.sig = bls.Signature.fromBytes(signature)

    return {
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