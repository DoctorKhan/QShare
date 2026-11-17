import CommonCrypto
import CryptoKit
import Foundation

enum QSError: Error, LocalizedError {
    case protocolViolation(String)
    case crypto(String)
    case io(String)

    var errorDescription: String? {
        switch self {
        case .protocolViolation(let message): return message
        case .crypto(let message): return message
        case .io(let message): return message
        }
    }
}

enum Role {
    case server, client
}

/// The four symmetric keys used after the UKEY2 handshake, plus the PIN shown to the user.
struct SessionKeys {
    let decryptKey: SymmetricKey
    let receiveHMACKey: SymmetricKey
    let encryptKey: SymmetricKey
    let sendHMACKey: SymmetricKey
    let pin: String
}

enum Ukey2 {
    static let nextProtocol = "AES_256_CBC-HMAC_SHA256"

    private static let d2dSalt = Data(SHA256.hash(data: Data("D2D".utf8)))
    private static let secureMessageSalt = Data(SHA256.hash(data: Data("SecureMessage".utf8)))

    /// Derives the session keys from the ECDH result and the raw handshake messages.
    static func deriveKeys(
        privateKey: P256.KeyAgreement.PrivateKey,
        peerKey: P256.KeyAgreement.PublicKey,
        clientInitMessage: Data,
        serverInitMessage: Data,
        role: Role
    ) throws -> SessionKeys {
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peerKey)
        let sharedBytes = shared.withUnsafeBytes { Data($0) }
        let derivedSecret = SymmetricKey(data: Data(SHA256.hash(data: sharedBytes)))

        var info = Data()
        info.append(clientInitMessage)
        info.append(serverInitMessage)

        let authString = hkdf(derivedSecret, salt: Data("UKEY2 v1 auth".utf8), info: info)
        let nextSecret = hkdf(derivedSecret, salt: Data("UKEY2 v1 next".utf8), info: info)

        let clientKey = hkdf(nextSecret, salt: d2dSalt, info: Data("client".utf8))
        let serverKey = hkdf(nextSecret, salt: d2dSalt, info: Data("server".utf8))

        let (incoming, outgoing) = role == .server ? (clientKey, serverKey) : (serverKey, clientKey)
        return SessionKeys(
            decryptKey: hkdf(incoming, salt: secureMessageSalt, info: Data("ENC:2".utf8)),
            receiveHMACKey: hkdf(incoming, salt: secureMessageSalt, info: Data("SIG:1".utf8)),
            encryptKey: hkdf(outgoing, salt: secureMessageSalt, info: Data("ENC:2".utf8)),
            sendHMACKey: hkdf(outgoing, salt: secureMessageSalt, info: Data("SIG:1".utf8)),
            pin: pin(from: authString)
        )
    }

    private static func hkdf(_ key: SymmetricKey, salt: Data, info: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: salt, info: info, outputByteCount: 32)
    }

    /// The 4-digit code both devices display so the user can confirm they match.
    static func pin(from authString: SymmetricKey) -> String {
        var hash = 0
        var multiplier = 1
        authString.withUnsafeBytes { buffer in
            for raw in buffer {
                let byte = Int(Int8(bitPattern: raw))
                hash = (hash + byte * multiplier) % 9973
                multiplier = (multiplier * 31) % 9973
            }
        }
        return String(format: "%04d", abs(hash))
    }

    /// Serialized `GenericPublicKey` for a P-256 key. Coordinates use Java's signed
    /// big-endian encoding, so a leading zero is added when the top bit is set.
    static func serializedPublicKey(_ key: P256.KeyAgreement.PublicKey) throws -> Data {
        let raw = key.x963Representation // 0x04 || X || Y
        guard raw.count == 65 else { throw QSError.crypto("Unexpected public key size") }
        var message = Securemessage_GenericPublicKey()
        message.type = .ecP256
        message.ecP256PublicKey.x = signedBytes(raw.subdata(in: 1..<33))
        message.ecP256PublicKey.y = signedBytes(raw.subdata(in: 33..<65))
        return try message.serializedData()
    }

    static func parsePublicKey(_ data: Data) throws -> P256.KeyAgreement.PublicKey {
        let message = try Securemessage_GenericPublicKey(serializedBytes: data)
        guard message.type == .ecP256, message.hasEcP256PublicKey else {
            throw QSError.crypto("Peer sent an unsupported public key type")
        }
        var raw = Data([0x04])
        raw.append(try unsignedCoordinate(message.ecP256PublicKey.x))
        raw.append(try unsignedCoordinate(message.ecP256PublicKey.y))
        return try P256.KeyAgreement.PublicKey(x963Representation: raw)
    }

    private static func signedBytes(_ coordinate: Data) -> Data {
        guard let first = coordinate.first, first & 0x80 != 0 else { return coordinate }
        return Data([0x00]) + coordinate
    }

    private static func unsignedCoordinate(_ signed: Data) throws -> Data {
        var bytes = [UInt8](signed)
        while bytes.count > 32, bytes.first == 0 { bytes.removeFirst() }
        guard bytes.count <= 32 else { throw QSError.crypto("Peer public key coordinate is too long") }
        return Data(repeating: 0, count: 32 - bytes.count) + Data(bytes)
    }
}

/// Encrypts and authenticates frames after the handshake (SecureMessage + DeviceToDeviceMessage).
final class SecureChannel {
    private let keys: SessionKeys
    private var sendSequence: Int32 = 0
    private var receiveSequence: Int32 = 0

    init(keys: SessionKeys) {
        self.keys = keys
    }

    var pin: String { keys.pin }

    func seal(_ plaintext: Data) throws -> Data {
        sendSequence += 1
        var d2d = Securegcm_DeviceToDeviceMessage()
        d2d.sequenceNumber = sendSequence
        d2d.message = plaintext

        let iv = Data.random(count: kCCBlockSizeAES128)
        var metadata = Securegcm_GcmMetadata()
        metadata.type = .deviceToDeviceMessage
        metadata.version = 1

        var headerAndBody = Securemessage_HeaderAndBody()
        headerAndBody.header.signatureScheme = .hmacSha256
        headerAndBody.header.encryptionScheme = .aes256Cbc
        headerAndBody.header.iv = iv
        headerAndBody.header.publicMetadata = try metadata.serializedData()
        headerAndBody.body = try Self.aesCBC(
            kCCEncrypt, key: keys.encryptKey, iv: iv, input: try d2d.serializedData())

        var message = Securemessage_SecureMessage()
        message.headerAndBody = try headerAndBody.serializedData()
        message.signature = Data(
            HMAC<SHA256>.authenticationCode(for: message.headerAndBody, using: keys.sendHMACKey))
        return try message.serializedData()
    }

    func open(_ data: Data) throws -> Data {
        let message = try Securemessage_SecureMessage(serializedBytes: data)
        guard message.hasHeaderAndBody, message.hasSignature else {
            throw QSError.crypto("Encrypted message is missing fields")
        }
        guard HMAC<SHA256>.isValidAuthenticationCode(
            message.signature, authenticating: message.headerAndBody, using: keys.receiveHMACKey)
        else {
            throw QSError.crypto("Message authentication failed")
        }
        let headerAndBody = try Securemessage_HeaderAndBody(serializedBytes: message.headerAndBody)
        guard headerAndBody.header.encryptionScheme == .aes256Cbc,
              headerAndBody.header.iv.count == kCCBlockSizeAES128
        else {
            throw QSError.crypto("Unsupported encryption scheme")
        }
        let decrypted = try Self.aesCBC(
            kCCDecrypt, key: keys.decryptKey, iv: headerAndBody.header.iv, input: headerAndBody.body)
        let d2d = try Securegcm_DeviceToDeviceMessage(serializedBytes: decrypted)
        receiveSequence += 1
        guard d2d.sequenceNumber == receiveSequence else {
            throw QSError.crypto("Out-of-order message (possible replay)")
        }
        return d2d.message
    }

    private static func aesCBC(_ operation: Int, key: SymmetricKey, iv: Data, input: Data) throws -> Data {
        var output = Data(count: input.count + kCCBlockSizeAES128)
        let capacity = output.count
        var written = 0
        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                input.withUnsafeBytes { inputBytes in
                    output.withUnsafeMutableBytes { outputBytes in
                        CCCrypt(
                            CCOperation(operation), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, keyBytes.count, ivBytes.baseAddress,
                            inputBytes.baseAddress, input.count,
                            outputBytes.baseAddress, capacity, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw QSError.crypto("AES operation failed (\(status))") }
        output.removeSubrange(written..<output.count)
        return output
    }
}
