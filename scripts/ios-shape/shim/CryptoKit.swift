// Shim of the CryptoKit surface GogSHA256 touches. TYPE CHECKING ONLY.
@_exported import Foundation

public struct SHA256Digest: Sequence, Hashable, Sendable {
    private let bytes: [UInt8]
    init(_ b: [UInt8]) { bytes = b }
    public func makeIterator() -> Array<UInt8>.Iterator { bytes.makeIterator() }
}

public enum SHA256 {
    public static func hash(data: some DataProtocol) -> SHA256Digest { SHA256Digest([]) }
}
