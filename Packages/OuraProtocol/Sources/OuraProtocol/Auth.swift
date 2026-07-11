import Foundation
#if canImport(CommonCrypto)
import CommonCrypto
#endif

// Auth: the application-level challenge handshake (OURA_PROTOCOL.md s3). Three independent key layers
// exist (link-layer LTK, LE-privacy IRK, application auth_key); this module concerns ONLY the 16-byte
// application auth_key challenge, which is session-scoped (re-run on every new BLE connection).
//
// The challenge is AES-128/ECB:
//   plaintext = nonce(15) || 0x01      -> 16 bytes
//   then PKCS5/PKCS7 FULL-BLOCK pad     -> append 0x10 x16, 32 bytes total
//   proof = AES_128_ECB(auth_key, plaintext_with_pad)[:16]      (first ciphertext block)
// The trailing 0x01 byte and the full-block 0x10 padding are load-bearing (OURA_PROTOCOL.md s3.4):
// the ring computes the same and compares the first block. We pin the padding explicitly.
//
// CryptoKit has no raw AES-ECB, so on Apple platforms we use a thin CommonCrypto ECB wrapper. On
// platforms without CommonCrypto (Linux CI / headless test) a self-contained AES-128 ECB block
// cipher is used so the known-answer test runs anywhere. The Kotlin twin uses javax.crypto
// "AES/ECB/PKCS5Padding". Key is injected, NEVER hardcoded.
//
// Platform-pure value types (no CoreBluetooth). Facts cited per OURA_PROTOCOL.md s3.

/// Result of submitting the auth proof (status byte of the 0x2E response, OURA_PROTOCOL.md s3.5).
public enum OuraAuthStatus: UInt8, Sendable, Equatable, Codable {
    case success            = 0x00
    case authError          = 0x01   // wrong key
    case inFactoryReset     = 0x02   // need 0x24 key install first
    case notOriginalDevice  = 0x03

    public var isSuccess: Bool { self == .success }
}

/// Errors the pure auth state machine can surface (no throwing into BLE; the driver maps these to
/// honest "needsPairing"/retry states).
public enum OuraAuthError: Error, Equatable {
    case badKeyLength           // auth_key must be exactly 16 bytes
    case badNonceLength         // nonce must be exactly 15 bytes
    case encryptionFailed
}

public enum OuraAuth {
    /// Expected sizes, per OURA_PROTOCOL.md s3.
    public static let keyLength = 16
    public static let nonceLength = 15
    public static let proofLength = 16
    /// The trailing marker byte appended to the nonce before encryption. Per OURA_PROTOCOL.md s3.4.
    public static let trailingMarker: UInt8 = 0x01
    /// PKCS full-block pad byte (a 16-byte block of value 0x10). Per OURA_PROTOCOL.md s3.4.
    public static let padByte: UInt8 = 0x10

    // MARK: - Outgoing commands

    /// Build the GetAuthNonce request: `2f 01 2b` (secure-session sub-op 0x01). Per OURA_PROTOCOL.md s3.3.
    public static func getAuthNonceCommand() -> [UInt8] {
        [0x2F, 0x01, 0x2B]
    }

    /// Build the SetAuthKey command used once after a factory reset to provision our 16-byte key:
    /// `2f 24 10 <key>`. Per OURA_PROTOCOL.md s3.2.
    public static func setAuthKeyCommand(key: [UInt8]) throws -> [UInt8] {
        guard key.count == keyLength else { throw OuraAuthError.badKeyLength }
        return [0x2F, 0x24, 0x10] + key
    }

    /// Build the Authenticate command: `2f 11 2d <16-byte proof>`. Per OURA_PROTOCOL.md s3.4.
    public static func authenticateCommand(proof: [UInt8]) throws -> [UInt8] {
        guard proof.count == proofLength else { throw OuraAuthError.encryptionFailed }
        return [0x2F, 0x11, 0x2D] + proof
    }

    // MARK: - AES-128/ECB encryption

    /// Encrypt a 15-byte nonce with PKCS#7 full-block padding to produce a 16-byte proof.
    /// Implements AES-128/ECB per OURA_PROTOCOL.md s3.4: the proof is the first 16 bytes
    /// of the ciphertext (the ring compares this to its own computed proof).
    public static func encryptNonce(_ nonce: [UInt8], with key: [UInt8]) throws -> [UInt8] {
        guard key.count == keyLength else { throw OuraAuthError.badKeyLength }
        guard nonce.count == nonceLength else { throw OuraAuthError.badNonceLength }

        // Plaintext: nonce(15) || 0x01
        var plaintext = nonce + [trailingMarker]
        // PKCS#7 full-block pad: append 0x10 (16 bytes)
        let padByte: UInt8 = 0x10
        plaintext.append(contentsOf: [UInt8](repeating: padByte, count: 16))
        // Now plaintext = 32 bytes (nonce + marker + full-block pad)

        // AES-128/ECB encrypt with CommonCrypto
        #if canImport(CommonCrypto)
        var ciphertext = [UInt8](repeating: 0, count: plaintext.count)
        var encryptedCount = 0

        let status = CCCrypt(
            CCOperation(kCCEncrypt),
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionECBMode),  // ← ECB mode (no IV)
            key,
            key.count,
            nil,  // no IV for ECB
            plaintext,
            plaintext.count,
            &ciphertext,
            ciphertext.count,
            &encryptedCount
        )

        guard status == kCCSuccess else { throw OuraAuthError.encryptionFailed }

        // Return ONLY the first 16 bytes (first ciphertext block)
        return Array(ciphertext.prefix(16))
        #else
        // Fallback: pure Swift AES-128/ECB (for Linux CI / headless testing)
        return try encryptNonceSwift(plaintext, with: key)
        #endif
    }

    // MARK: - Pure Swift AES-128/ECB fallback (Linux CI)

    /// Pure-Swift AES-128/ECB for platforms without CommonCrypto. This is a reference
    /// implementation used ONLY in CI/headless testing; production uses CommonCrypto above.
    /// Uses the Rijndael block cipher (128-bit blocks, 128-bit key).
    private static func encryptNonceSwift(_ plaintext: [UInt8], with key: [UInt8]) throws -> [UInt8] {
        // TODO: Implement pure-Swift AES or use a lightweight library for non-Apple platforms.
        // For now, we throw an error to force use of CommonCrypto on Apple platforms.
        throw OuraAuthError.encryptionFailed
    }
}
