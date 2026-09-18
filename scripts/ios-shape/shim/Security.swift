// Shim of the Security surface KeychainSecureStore touches. TYPE CHECKING ONLY.
// Constant VALUES are irrelevant here; the shapes and the call signatures are the point.
//
// `nonisolated(unsafe)` on every constant: Swift 6 isolates globals declared in Swift source,
// but the real kSec* are `let` constants imported from C headers and carry no isolation. Without
// this the harness reports a dozen main-actor errors that do NOT exist against the real SDK —
// harness noise, not defects. Getting this wrong in the other direction would be the dangerous
// one, so it is called out rather than quietly patched.
@_exported import Foundation

public typealias OSStatus = Int32
public typealias CFTypeRef = Any
public typealias CFDictionary = NSDictionary

public nonisolated(unsafe) let kSecClass: String = "class"
public nonisolated(unsafe) let kSecClassGenericPassword: String = "genp"
public nonisolated(unsafe) let kSecAttrService: String = "svce"
public nonisolated(unsafe) let kSecAttrAccount: String = "acct"
public nonisolated(unsafe) let kSecValueData: String = "v_Data"
public nonisolated(unsafe) let kSecReturnData: String = "r_Data"
public nonisolated(unsafe) let kSecMatchLimit: String = "m_Limit"
public nonisolated(unsafe) let kSecMatchLimitOne: String = "m_LimitOne"
public nonisolated(unsafe) let kSecAttrAccessible: String = "pdmn"
public nonisolated(unsafe) let kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly: String = "cku"

public nonisolated(unsafe) let errSecSuccess: OSStatus = 0
public nonisolated(unsafe) let errSecItemNotFound: OSStatus = -25300
public nonisolated(unsafe) let errSecDuplicateItem: OSStatus = -25299

public func SecItemCopyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus { 0 }
public func SecItemAdd(_ attributes: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus { 0 }
public func SecItemUpdate(_ query: CFDictionary, _ attributesToUpdate: CFDictionary) -> OSStatus { 0 }
public func SecItemDelete(_ query: CFDictionary) -> OSStatus { 0 }
