import Foundation

extension Data {
    /// Lowercase hex, the encoding every Nostr field uses.
    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }

    /// Strict hex decode: even length, hex digits only, or nil.
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
