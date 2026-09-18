// Shim of the os_log surface GogLog touches. TYPE CHECKING ONLY.
@_exported import Foundation

public struct OSLog: Sendable {
    public static let `default` = OSLog()
    public static let disabled = OSLog()
}

public struct OSLogType: Sendable, Equatable {
    let raw: UInt8
    public static let `default` = OSLogType(raw: 0)
    public static let info = OSLogType(raw: 1)
    public static let debug = OSLogType(raw: 2)
    public static let error = OSLogType(raw: 16)
    public static let fault = OSLogType(raw: 17)
}

public func os_log(_ message: StaticString, log: OSLog = .default,
                   type: OSLogType = .default, _ args: any CVarArg...) {}
