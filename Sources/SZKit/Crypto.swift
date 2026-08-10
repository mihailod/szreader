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

extension AES {

    /// Streaming AES-128-CTR over a file, in place of loading it into memory.
    ///
    /// Mega serves file bytes encrypted; the counter block is the 8-byte nonce
    /// followed by an 8-byte big-endian block counter starting at zero.
    ///
    /// UNVERIFIED end to end against a real Mega download — the phase-2 live
    /// checks covered attribute decryption (CBC), not file bodies. The CTR
    /// usage here is pinned to an OpenSSL vector, so the primitive is right;
    /// what remains unproven is Mega's counter convention. If a decrypted
    /// archive fails its magic-byte check, suspect this first.
    static func decryptCTR(source: URL, destination: URL,
                           key: Data, nonce: Data,
                           chunkSize: Int = 1 << 20) throws {
        guard key.count == kCCKeySizeAES128, nonce.count == 8 else {
            throw CryptoError.badParameters
        }
        var iv = nonce
        iv.append(contentsOf: [UInt8](repeating: 0, count: 8))

        var cryptor: CCCryptorRef?
        let status = key.withUnsafeBytes { keyBuf in
            iv.withUnsafeBytes { ivBuf in
                CCCryptorCreateWithMode(
                    CCOperation(kCCDecrypt), CCMode(kCCModeCTR),
                    CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
                    ivBuf.baseAddress, keyBuf.baseAddress, key.count,
                    nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
            }
        }
        guard status == kCCSuccess, let cryptor else { throw CryptoError.cryptorFailed }
        defer { CCCryptorRelease(cryptor) }

        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        var out = [UInt8](repeating: 0, count: chunkSize + kCCBlockSizeAES128)
        while true {
            let chunk = input.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            var moved = 0
            let rc = chunk.withUnsafeBytes { inBuf in
                CCCryptorUpdate(cryptor, inBuf.baseAddress, chunk.count,
                                &out, out.count, &moved)
            }
            guard rc == kCCSuccess else { throw CryptoError.cryptorFailed }
            if moved > 0 { output.write(Data(out[0..<moved])) }
        }
        var finalMoved = 0
        guard CCCryptorFinal(cryptor, &out, out.count, &finalMoved) == kCCSuccess else {
            throw CryptoError.cryptorFailed
        }
        if finalMoved > 0 { output.write(Data(out[0..<finalMoved])) }
    }
}

enum CryptoError: Error, CustomStringConvertible {
    case badParameters
    case cryptorFailed

    var description: String {
        switch self {
        case .badParameters: return "bad key or nonce length"
        case .cryptorFailed: return "CommonCrypto cryptor failed"
        }
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
