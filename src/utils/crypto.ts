import bs58 from 'bs58'
import secp256k1 from 'secp256k1'

/**
 * Decode bs58+ripemd160-checksum encoded public key.
 */
const decodePublic = (encodedKey: string) => {
    const prefix = encodedKey.slice(0, 3)
    encodedKey = encodedKey.slice(3)
    const buffer = bs58.decode(encodedKey)
    const key = buffer.slice(0, -4)
    return { key, prefix }
}

export const isValidL1PubKey = (publicKey: string) => {
    if (typeof publicKey !== 'string' || publicKey.length > 53)
        return false
    try {
        let decoded = decodePublic(publicKey)
        return secp256k1.publicKeyVerify(decoded.key)
    } catch {
        return false
    }
}