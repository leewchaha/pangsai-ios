import CryptoKit
import Foundation

// Compiled into BOTH the app and the Notification Service Extension.

/// AES-256-GCM sealing of ping payloads. Keys are 32 random bytes, base64url encoded.
/// Output is base64url(nonce || ciphertext || tag).
struct AESSealer: PayloadSealer {
    enum SealError: Error { case badKey, badInput }

    private func key(_ base64URL: String) throws -> SymmetricKey {
        guard let data = Data(base64URLEncoded: base64URL), data.count == 32 else { throw SealError.badKey }
        return SymmetricKey(data: data)
    }

    func seal(_ plaintext: Data, keyBase64URL: String) throws -> String {
        let box = try AES.GCM.seal(plaintext, using: try key(keyBase64URL))
        guard let combined = box.combined else { throw SealError.badInput }
        return combined.base64URLEncodedString()
    }

    func open(_ sealed: String, keyBase64URL: String) throws -> Data {
        guard let data = Data(base64URLEncoded: sealed) else { throw SealError.badInput }
        let box = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(box, using: try key(keyBase64URL))
    }
}
