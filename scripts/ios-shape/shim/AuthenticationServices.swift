// Shim of the AuthenticationServices surface the GOG SDK touches. TYPE CHECKING ONLY.
@_exported import Foundation
@_exported import UIKit

public typealias ASPresentationAnchor = UIWindow

public struct ASWebAuthenticationSessionError: Error, Sendable {
    public enum Code: Sendable { case canceledLogin, presentationContextNotProvided,
                                     presentationContextInvalid }
    public let code: Code
    public init(code: Code) { self.code = code }
}

@MainActor public protocol ASWebAuthenticationPresentationContextProviding: NSObjectProtocol {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor
}

@MainActor public final class ASWebAuthenticationSession: NSObject {
    public enum Callback: Sendable {
        case https(host: String, path: String)
        case customScheme(String)
    }
    public init(url: URL, callback: Callback,
                completionHandler: @escaping (URL?, (any Error)?) -> Void) { super.init() }
    public weak var presentationContextProvider: (any ASWebAuthenticationPresentationContextProviding)?
    public var prefersEphemeralWebBrowserSession: Bool = false
    @discardableResult public func start() -> Bool { false }
    public func cancel() {}
}
