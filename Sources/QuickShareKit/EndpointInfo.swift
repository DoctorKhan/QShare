import Foundation

/// The kind of device shown on the other side (Android picks an icon from this).
public enum DeviceType: Int, Sendable {
    case unknown = 0, phone = 1, tablet = 2, laptop = 3, car = 4, foldable = 5, xr = 6
}

/// "Endpoint info" as used in the mDNS TXT record and in the connection request.
struct EndpointInfo {
    var deviceType: DeviceType
    var name: String?

    /// Serializes a visible endpoint with the given name.
    func serialized() -> Data {
        var data = Data()
        // version 0 | visibility 0 (visible) | device type | reserved
        data.append(UInt8(deviceType.rawValue << 1))
        data.append(Data.random(count: 16))
        var nameBytes = Data((name ?? "Mac").utf8)
        if nameBytes.count > 255 {
            nameBytes = nameBytes.prefix(255)
            // Don't cut a UTF-8 sequence in half.
            while String(data: nameBytes, encoding: .utf8) == nil, !nameBytes.isEmpty {
                nameBytes.removeLast()
            }
        }
        data.append(UInt8(nameBytes.count))
        data.append(nameBytes)
        return data
    }

    init(deviceType: DeviceType, name: String?) {
        self.deviceType = deviceType
        self.name = name
    }

    init?(data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 17 else { return nil }
        deviceType = DeviceType(rawValue: Int((bytes[0] >> 1) & 0x7)) ?? .unknown
        let hidden = (bytes[0] >> 4) & 0x1 == 1
        if !hidden, bytes.count > 17 {
            let length = Int(bytes[17])
            if length > 0, bytes.count >= 18 + length {
                name = String(decoding: bytes[18..<(18 + length)], as: UTF8.self)
            }
        }
    }
}

extension Data {
    static func random(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    func urlSafeBase64() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum EndpointID {
    /// 4 random alphanumeric characters identifying this device to peers.
    static func generate() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<4).map { _ in alphabet.randomElement()! })
    }

    static func isValid(_ id: String) -> Bool {
        id.utf8.count == 4 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// mDNS service instance name for a given endpoint ID.
    static func serviceName(for id: String) -> String {
        var data = Data([0x23])
        data.append(Data(id.utf8))
        data.append(contentsOf: [0xFC, 0x9F, 0x5E, 0x00, 0x00])
        return data.urlSafeBase64()
    }
}
