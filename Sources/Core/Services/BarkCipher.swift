import CommonCrypto
import Foundation

/// Encrypts a push body the way the Bark app expects.
///
/// Bark can carry its whole request encrypted, so the server and APNs see only a
/// ciphertext. The app decrypts with a key the user stored on the device, and the
/// settings here have to match that key exactly — the algorithm, the mode, the
/// key, and for two of the three modes an IV. A mismatch is not a failed request:
/// the push arrives and the phone shows "Decryption Failed", which is a long way
/// from the setting that caused it. So the field count is validated before
/// anything is sent.
///
/// This is the one part of the payload assembled with CommonCrypto rather than
/// CryptoKit. CryptoKit's `AES.GCM` writes its nonce into the sealed box, and the
/// app — which uses CryptoSwift — treats the IV as a separate field and expects
/// ciphertext followed by tag. The formats do not line up, and the difference is
/// invisible until a phone fails to decrypt. CommonCrypto's own GCM API produces
/// exactly what the app reads, and it covers CBC and ECB besides, so there is one
/// implementation rather than two.
enum BarkCipher {

    /// The key sizes the app accepts, and the modes it offers.
    enum Algorithm: String, CaseIterable {
        case aes128 = "AES128"
        case aes192 = "AES192"
        case aes256 = "AES256"

        /// The key length the algorithm requires, in bytes.
        var keyLength: Int {
            switch self {
            case .aes128: return kCCKeySizeAES128
            case .aes192: return kCCKeySizeAES192
            case .aes256: return kCCKeySizeAES256
            }
        }
    }

    enum Mode: String, CaseIterable {
        case cbc = "CBC"
        case ecb = "ECB"
        case gcm = "GCM"

        /// Whether this mode needs an IV.
        ///
        /// ECB encrypts each block on its own, so it has nothing to chain and no
        /// IV. The app's own validation says the same, and asks for 16 characters
        /// for CBC and 12 for GCM — a GCM nonce is 96 bits by convention.
        var ivLength: Int {
            switch self {
            case .cbc: return kCCBlockSizeAES128
            case .ecb: return 0
            case .gcm: return 12
            }
        }
    }

    enum Failure: LocalizedError {
        case keyLength(Int)
        case ivLength(Int)
        case encryption(CCCryptorStatus)

        var errorDescription: String? {
            switch self {
            case .keyLength(let expected):
                return "The key must be \(expected) characters for this algorithm."
            case .ivLength(let expected):
                return "The IV must be \(expected) characters for this mode."
            case .encryption(let status):
                return "Encryption failed (CommonCrypto status \(status))."
            }
        }
    }

    /// The settings the user stored, and whether they are complete.
    struct Settings {
        var isEnabled: Bool
        var algorithm: Algorithm
        var mode: Mode
        var key: String

        /// Whether a push should be encrypted with these settings.
        ///
        /// The switch decides, and the key has to be there for the decision to
        /// mean anything. Reading the key alone is not enough: turning the switch
        /// off leaves the key in storage — deliberately, so it is not retyped when
        /// it is turned back on — and a key that is merely present would keep
        /// encrypting every push after the user had switched it off.
        var isUsable: Bool { isEnabled && !key.isEmpty }

        /// What is wrong with the settings, or `nil` when they are usable.
        func problem() -> Failure? {
            key.count == algorithm.keyLength ? nil : .keyLength(algorithm.keyLength)
        }
    }

    /// Encrypts a JSON body and returns the fields to send in its place.
    ///
    /// The result replaces the whole request body: what travels is the ciphertext
    /// and, when the mode uses one, the IV. Anything else sent alongside would be
    /// readable, and the app puts the decrypted dictionary in place of the body
    /// entirely — so a plaintext field beside a ciphertext one is either ignored
    /// or, worse, shown unencrypted.
    ///
    /// The IV is generated here, per push, rather than configured. That is not a
    /// preference: the app's settings screen has no IV field — it was removed, and
    /// the IV travels in the request instead, with the app taking whatever the
    /// request carries over anything it has stored. A fixed IV would also be the
    /// wrong thing to want: reusing one under the same key leaks where two
    /// plaintexts agree.
    static func encrypt(json: String, settings: Settings) throws -> [String: String] {
        if let problem = settings.problem() { throw problem }

        let plaintext = Data(json.utf8)
        let key = Array(settings.key.utf8)
        let iv = settings.mode.ivLength > 0 ? randomIV(length: settings.mode.ivLength) : nil

        let ciphertext: Data
        switch settings.mode {
        case .cbc, .ecb:
            ciphertext = try crypt(
                plaintext, key: key, iv: iv,
                algorithm: CCAlgorithm(kCCAlgorithmAES),
                options: settings.mode == .ecb
                    ? CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode)
                    : CCOptions(kCCOptionPKCS7Padding)
            )
        case .gcm:
            ciphertext = try gcm(plaintext, key: key, iv: iv ?? [])
        }

        var fields = ["ciphertext": ciphertext.base64EncodedString()]
        // ECB has none to send; the app derives nothing from its absence.
        if let iv {
            fields["iv"] = String(decoding: iv, as: UTF8.self)
        }
        return fields
    }

    /// A fresh IV, as the app generates its own: lower-case hexadecimal
    /// characters, not arbitrary bytes.
    ///
    /// The alphabet matters because it is what the app's own example script uses
    /// and what its sample output contains; an IV of random bytes would have to be
    /// transported in some encoding, and the app decodes this field as text.
    private static func randomIV(length: Int) -> [UInt8] {
        let alphabet = Array("0123456789abcdef".utf8)
        return (0..<length).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] }
    }

    // MARK: - CBC and ECB

    /// One-shot AES with PKCS#7 padding.
    ///
    /// PKCS#7 is the only padding the app offers, so it is the only one here —
    /// there is no setting to send and no combination the app could decrypt if
    /// there were.
    private static func crypt(
        _ plaintext: Data, key: [UInt8], iv: [UInt8]?,
        algorithm: CCAlgorithm, options: CCOptions
    ) throws -> Data {
        // A block of headroom for the padding the cipher may add.
        var output = Data(count: plaintext.count + kCCBlockSizeAES128)
        var written = 0

        let status = output.withUnsafeMutableBytes { outputBytes -> CCCryptorStatus in
            plaintext.withUnsafeBytes { plaintextBytes in
                key.withUnsafeBytes { keyBytes in
                    // ECB's IV must be absent; passing a buffer the cipher ignores
                    // is harmless, but passing the wrong length is not, so the
                    // pointer is nil when there is no IV.
                    let ivStatus: CCCryptorStatus? = iv.map { ivBytes in
                        ivBytes.withUnsafeBytes { ivPointer in
                            CCCrypt(
                                CCOperation(kCCEncrypt), algorithm, options,
                                keyBytes.baseAddress, key.count, ivPointer.baseAddress,
                                plaintextBytes.baseAddress, plaintext.count,
                                outputBytes.baseAddress, outputBytes.count, &written
                            )
                        }
                    }
                    if let ivStatus { return ivStatus }
                    return CCCrypt(
                        CCOperation(kCCEncrypt), algorithm, options,
                        keyBytes.baseAddress, key.count, nil,
                        plaintextBytes.baseAddress, plaintext.count,
                        outputBytes.baseAddress, outputBytes.count, &written
                    )
                }
            }
        }

        guard status == kCCSuccess else { throw Failure.encryption(status) }
        return output.prefix(written)
    }

    // MARK: - GCM

    /// AES-GCM, with the tag appended the way the app's decryptor reads it.
    ///
    /// Written out rather than delegated, because there is nothing on iOS to
    /// delegate to that produces this: CryptoKit's `AES.GCM` seals the nonce into
    /// the box, and the app — which uses CryptoSwift — takes the IV as a separate
    /// field and expects ciphertext followed by tag. CommonCrypto's GCM entry
    /// points exist but are not in the public header, and on macOS the one-shot
    /// signature answers `kCCUnimplemented`.
    ///
    /// GCM is CTR encryption plus GHASH authentication, and AES-ECB gives the one
    /// primitive both need — a single-block encryption under the key — so the
    /// whole of it is the arithmetic below. Verified against `cryptography`'s
    /// output for a known vector: identical bytes, tag included.
    private static func gcm(_ plaintext: Data, key: [UInt8], iv: [UInt8]) throws -> Data {
        let h = encryptBlock([UInt8](repeating: 0, count: 16), key: key)
        let j0 = initialCounter(iv, h: h)
        let counter = j0
        let ciphertext = ctr(plaintext, key: key, counter: counter)
        let tag = authenticationTag(ciphertext, h: h, j0: j0, key: key)
        return ciphertext + tag
    }

    /// One AES block, under the key, with no chaining.
    ///
    /// ECB with a single block *is* the raw block cipher — there is nothing for
    /// the mode to chain — which is what makes it usable as GCM's primitive.
    private static func encryptBlock(_ block: [UInt8], key: [UInt8]) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
        var written = 0
        _ = output.withUnsafeMutableBytes { outputBytes in
            block.withUnsafeBytes { blockBytes in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode), keyBytes.baseAddress, key.count, nil,
                        blockBytes.baseAddress, block.count,
                        outputBytes.baseAddress, outputBytes.count, &written
                    )
                }
            }
        }
        return output
    }

    /// `J0`: the counter GCM starts from.
    ///
    /// A 96-bit IV is used directly, followed by a counter of one — the app
    /// requires exactly 12 characters for GCM, so this is the only branch that
    /// runs. The general case is kept because the rule it implements is the
    /// specification's, and writing only the special case would make the code
    /// look as though the special case were the rule.
    private static func initialCounter(_ iv: [UInt8], h: [UInt8]) -> [UInt8] {
        if iv.count == 12 { return iv + [0, 0, 0, 1] }

        var padded = iv
        while padded.count % 16 != 0 { padded.append(0) }
        var blocks: [[UInt8]] = stride(from: 0, to: padded.count, by: 16).map {
            Array(padded[$0..<$0 + 16])
        }
        var lengthBlock = [UInt8](repeating: 0, count: 16)
        withUnsafeBytes(of: UInt64(iv.count * 8).bigEndian) {
            lengthBlock.replaceSubrange(8..<16, with: $0)
        }
        blocks.append(lengthBlock)
        return ghash(h: h, blocks)
    }

    /// AES-CTR over the plaintext, starting one counter past `J0`.
    private static func ctr(_ plaintext: Data, key: [UInt8], counter: [UInt8]) -> Data {
        var counter = counter
        var output = Data()
        var remaining = [UInt8](plaintext)

        while !remaining.isEmpty {
            increment(&counter)
            let keystream = encryptBlock(counter, key: key)
            let count = min(16, remaining.count)
            for index in 0..<count { output.append(remaining[index] ^ keystream[index]) }
            remaining.removeFirst(count)
        }
        return output
    }

    /// The authentication tag: `AES_K(J0) ⊕ GHASH_H(ciphertext ‖ lengths)`.
    private static func authenticationTag(
        _ ciphertext: Data, h: [UInt8], j0: [UInt8], key: [UInt8]
    ) -> Data {
        var blocks = chunked(ciphertext)
        var lengthBlock = [UInt8](repeating: 0, count: 16)
        // No additional authenticated data, so its length is zero.
        withUnsafeBytes(of: UInt64(0).bigEndian) {
            lengthBlock.replaceSubrange(0..<8, with: $0)
        }
        withUnsafeBytes(of: UInt64(ciphertext.count * 8).bigEndian) {
            lengthBlock.replaceSubrange(8..<16, with: $0)
        }
        blocks.append(lengthBlock)

        let s = ghash(h: h, blocks)
        return Data(zip(encryptBlock(j0, key: key), s).map(^))
    }

    /// Advances the counter by one, in place.
    ///
    /// The last 32 bits are what GCM increments; the rest of the block is the
    /// fixed prefix. Carrying across all sixteen bytes would eventually differ,
    /// but only past 2^32 blocks under one key, which one notification cannot
    /// reach.
    private static func increment(_ counter: inout [UInt8]) {
        for index in stride(from: 15, through: 12, by: -1) {
            counter[index] = counter[index] &+ 1
            if counter[index] != 0 { break }
        }
    }

    /// Splits data into 16-byte blocks, zero-padded at the end.
    private static func chunked(_ data: Data) -> [[UInt8]] {
        guard !data.isEmpty else { return [] }
        var bytes = [UInt8](data)
        while bytes.count % 16 != 0 { bytes.append(0) }
        return stride(from: 0, to: bytes.count, by: 16).map { Array(bytes[$0..<$0 + 16]) }
    }

    /// GHASH: a polynomial hash over GF(2^128).
    private static func ghash(h: [UInt8], _ blocks: [[UInt8]]) -> [UInt8] {
        var y = [UInt8](repeating: 0, count: 16)
        for block in blocks { y = multiply(xor(y, block), h) }
        return y
    }

    /// Multiplication in GF(2^128), bit by bit.
    ///
    /// GCM's field uses the reduction polynomial `x^128 + x^7 + x^2 + x + 1`, so
    /// a left shift that carries out is folded back by xoring `0xe1` into the
    /// first byte. Slow next to a table-driven version and irrelevant here: a
    /// push carries a few hundred bytes, and this runs once per notification.
    private static func multiply(_ x: [UInt8], _ y: [UInt8]) -> [UInt8] {
        var product = [UInt8](repeating: 0, count: 16)
        var shifted = y

        for bit in 0..<128 {
            // Bits are taken most-significant first, which is GCM's order rather
            // than the one a number would use.
            if (x[bit / 8] >> (7 - UInt8(bit % 8))) & 1 == 1 {
                product = xor(product, shifted)
            }
            let carriedOut = shifted[15] & 1
            var carry: UInt8 = 0
            for index in 0..<16 {
                let next = shifted[index] & 1
                shifted[index] = (shifted[index] >> 1) | (carry << 7)
                carry = next
            }
            if carriedOut == 1 { shifted[0] ^= 0xe1 }
        }
        return product
    }

    private static func xor(_ left: [UInt8], _ right: [UInt8]) -> [UInt8] {
        zip(left, right).map(^)
    }

}
