import CommonCrypto
import Foundation

/// AES primitives needed by the Mega host.
///
/// CryptoKit has no raw AES-CBC/CTR, so CommonCrypto it is.
enum AES {

    /// AES-128-CBC decrypt, zero IV, no padding — the shape Mega uses for the
    /// encrypted attribute blob that carries the filename.
    static func decryptCBCNoPadding(_ data: Data, key: Data) -> Data? {
        guard key.count == kCCKeySizeAES128, data.count % kCCBlockSizeAES128 == 0,
              !data.isEmpty else { return nil }
        let capacity = data.count            // read before the exclusive access
        var out = Data(count: capacity)
        var moved = 0
        let status: CCCryptorStatus = out.withUnsafeMutableBytes { outBuf in
            data.withUnsafeBytes { inBuf in
                key.withUnsafeBytes { keyBuf in
                    let iv = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
                    return CCCrypt(CCOperation(kCCDecrypt),
                                   CCAlgorithm(kCCAlgorithmAES),
                                   CCOptions(0),                 // no padding
                                   keyBuf.baseAddress, key.count,
                                   iv,
                                   inBuf.baseAddress, capacity,
                                   outBuf.baseAddress, capacity,
                                   &moved)
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return out.prefix(moved)
    }
}

enum Base64URL {
    static func decode(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+")
                 .replacingOccurrences(of: "_", with: "/")
        t += String(repeating: "=", count: (4 - t.count % 4) % 4)
        return Data(base64Encoded: t)
    }

    static func encode(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
