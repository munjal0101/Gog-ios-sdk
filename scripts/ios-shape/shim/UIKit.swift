// Shim of the UIKit surface the GOG SDK touches. TYPE CHECKING ONLY.
// @MainActor annotations mirror the real UIKit overlay — that fidelity is the
// entire point, since Swift 6 isolation errors are the likeliest first-compile failure.
@_exported import Foundation
@_exported import QuartzCore

// Linux Swift has no Objective-C runtime, so `Selector` and `#selector` do not exist.
// Sources are rewritten (see prepare.py) to use this stand-in. What that costs is stated
// plainly in the report: selector TARGETS are not verified here — only everything else.
public struct Selector: Hashable, Sendable {
    public let name: String
    public init(_ name: String) { self.name = name }
}

// ── geometry / graphics ────────────────────────────────────────────────────
public struct UIEdgeInsets: Sendable { public var top, left, bottom, right: CGFloat
    public init(top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) {
        self.top = top; self.left = left; self.bottom = bottom; self.right = right } }

public final class UIColor: @unchecked Sendable {
    public static let black = UIColor(); public static let white = UIColor()
    public static let clear = UIColor()
    public func withAlphaComponent(_ alpha: CGFloat) -> UIColor { self }
    public var cgColor: CGColor { CGColor() }
}

public final class UIFont: @unchecked Sendable {
    public struct Weight: Hashable, Sendable { public let raw: Double
        public init(_ r: Double) { raw = r }
        public static let regular = Weight(0); public static let semibold = Weight(0.3)
        public static let bold = Weight(0.4) }
    public static func systemFont(ofSize: CGFloat, weight: Weight = .regular) -> UIFont { UIFont() }
}

public final class UIImage: @unchecked Sendable {
    public init?(data: Data) { if data.isEmpty { return nil } }
    public init() {}
}

@MainActor public final class UIBezierPath {
    public init(arcCenter: CGPoint, radius: CGFloat, startAngle: CGFloat,
                endAngle: CGFloat, clockwise: Bool) {}
    public var cgPath: CGPath { CGPath() }
}

// ── layout ─────────────────────────────────────────────────────────────────
@MainActor open class NSLayoutConstraint {
    public static func activate(_ constraints: [NSLayoutConstraint]) {}
}
@MainActor open class NSLayoutAnchor<AnchorType> {
    open func constraint(equalTo anchor: NSLayoutAnchor<AnchorType>,
                         constant: CGFloat = 0) -> NSLayoutConstraint { NSLayoutConstraint() }
}
@MainActor public final class NSLayoutXAxisAnchor: NSLayoutAnchor<AnyObject> {}
@MainActor public final class NSLayoutYAxisAnchor: NSLayoutAnchor<AnyObject> {}
@MainActor public final class NSLayoutDimension: NSLayoutAnchor<AnyObject> {
    public func constraint(equalToConstant c: CGFloat) -> NSLayoutConstraint { NSLayoutConstraint() }
}
@MainActor public class UILayoutGuide {
    public var topAnchor: NSLayoutYAxisAnchor { NSLayoutYAxisAnchor() }
    public var bottomAnchor: NSLayoutYAxisAnchor { NSLayoutYAxisAnchor() }
    public var leadingAnchor: NSLayoutXAxisAnchor { NSLayoutXAxisAnchor() }
    public var trailingAnchor: NSLayoutXAxisAnchor { NSLayoutXAxisAnchor() }
    public var widthAnchor: NSLayoutDimension { NSLayoutDimension() }
    public var heightAnchor: NSLayoutDimension { NSLayoutDimension() }
    public var centerXAnchor: NSLayoutXAxisAnchor { NSLayoutXAxisAnchor() }
    public var centerYAnchor: NSLayoutYAxisAnchor { NSLayoutYAxisAnchor() }
}

// ── touches / presses ──────────────────────────────────────────────────────
@MainActor public class UITouch: NSObject {}
@MainActor public class UIEvent: NSObject {}
@MainActor public class UIPress: NSObject {}
@MainActor public class UIPressesEvent: UIEvent {}

// ── gesture recognisers ────────────────────────────────────────────────────
@MainActor public protocol UIGestureRecognizerDelegate: NSObjectProtocol {
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool
}
extension UIGestureRecognizerDelegate {
    public func gestureRecognizer(_ g: UIGestureRecognizer,
                                  shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { false }
}

@MainActor open class UIGestureRecognizer: NSObject {
    public enum State: Sendable { case possible, began, changed, ended, cancelled, failed, recognized }
    public init(target: Any?, action: Selector?) { super.init() }
    open var state: State = .possible
    open var cancelsTouchesInView: Bool = true
    open var delaysTouchesBegan: Bool = false
    open var delaysTouchesEnded: Bool = true
    weak open var delegate: (any UIGestureRecognizerDelegate)?
    open func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {}
    open func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {}
    open func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {}
    open func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {}
    open func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {}
    open func reset() {}
}
@MainActor public final class UITapGestureRecognizer: UIGestureRecognizer {}

// ── views ──────────────────────────────────────────────────────────────────
@MainActor open class UIView: NSObject {
    public enum ContentMode: Sendable { case scaleToFill, scaleAspectFit, scaleAspectFill, center }
    public override init() { super.init() }
    open var backgroundColor: UIColor?
    open var isUserInteractionEnabled: Bool = true
    open var translatesAutoresizingMaskIntoConstraints: Bool = true
    open var contentMode: ContentMode = .scaleToFill
    open var isAccessibilityElement: Bool = false
    open var accessibilityTraits: UIAccessibilityTraits = []
    open var accessibilityLabel: String?
    open var layer: CALayer { CALayer() }
    open var safeAreaLayoutGuide: UILayoutGuide { UILayoutGuide() }
    open var gestureRecognizers: [UIGestureRecognizer]?
    open func addSubview(_ view: UIView) {}
    open func addGestureRecognizer(_ g: UIGestureRecognizer) {}
    open func removeGestureRecognizer(_ g: UIGestureRecognizer) {}
    open var topAnchor: NSLayoutYAxisAnchor { NSLayoutYAxisAnchor() }
    open var bottomAnchor: NSLayoutYAxisAnchor { NSLayoutYAxisAnchor() }
    open var leadingAnchor: NSLayoutXAxisAnchor { NSLayoutXAxisAnchor() }
    open var trailingAnchor: NSLayoutXAxisAnchor { NSLayoutXAxisAnchor() }
    open var widthAnchor: NSLayoutDimension { NSLayoutDimension() }
    open var heightAnchor: NSLayoutDimension { NSLayoutDimension() }
    open var centerXAnchor: NSLayoutXAxisAnchor { NSLayoutXAxisAnchor() }
    open var centerYAnchor: NSLayoutYAxisAnchor { NSLayoutYAxisAnchor() }
    open var offsetParent: UIView? { nil }
}

public struct UIAccessibilityTraits: OptionSet, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public static let button = UIAccessibilityTraits(rawValue: 1)
}

@MainActor public final class UIImageView: UIView {
    public init(image: UIImage?) { super.init() }
}
@MainActor public final class UILabel: UIView {
    public var text: String?
    public var textColor: UIColor?
    public var textAlignment: NSTextAlignment = .natural
    public var font: UIFont?
}
public enum NSTextAlignment: Sendable { case left, center, right, justified, natural }

@MainActor public final class UIWindow: UIView {
    public var isKeyWindow: Bool { false }
    public var rootViewController: UIViewController?
}

// ── view controllers ───────────────────────────────────────────────────────
public enum UIModalPresentationStyle: Sendable { case automatic, fullScreen, pageSheet, overFullScreen }
public enum UIModalTransitionStyle: Sendable { case coverVertical, flipHorizontal, crossDissolve }
public struct UIInterfaceOrientationMask: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let portrait = UIInterfaceOrientationMask(rawValue: 1)
    public static let all = UIInterfaceOrientationMask(rawValue: 0xF)
}

@MainActor open class UIViewController: NSObject {
    public init(nibName: String?, bundle: Bundle?) { super.init() }
    public required init?(coder: NSCoder) { super.init() }
    open var view: UIView! = UIView()
    open var modalPresentationStyle: UIModalPresentationStyle = .automatic
    open var modalTransitionStyle: UIModalTransitionStyle = .coverVertical
    open var isModalInPresentation: Bool = false
    open var prefersStatusBarHidden: Bool { false }
    open var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }
    open var presentedViewController: UIViewController? { nil }
    open var presentingViewController: UIViewController? { nil }
    open func viewDidLoad() {}
    open func viewDidDisappear(_ animated: Bool) {}
    open func present(_ vc: UIViewController, animated: Bool, completion: (() -> Void)? = nil) {}
    open func dismiss(animated: Bool, completion: (() -> Void)? = nil) {}
}

// ── scenes / application ───────────────────────────────────────────────────
@MainActor open class UIScene: NSObject {
    public enum ActivationState: Sendable { case unattached, foregroundActive, foregroundInactive, background }
    open var activationState: ActivationState { .background }
}
@MainActor public final class UIWindowScene: UIScene {
    public var windows: [UIWindow] { [] }
}

@MainActor public final class UIApplication {
    public enum State: Sendable { case active, inactive, background }
    public struct OpenExternalURLOptionsKey: Hashable, Sendable, RawRepresentable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
    }
    public static let shared = UIApplication()
    public var applicationState: State { .active }
    public var connectedScenes: Set<UIScene> { [] }
    public func open(_ url: URL,
                     options: [OpenExternalURLOptionsKey: Any] = [:],
                     completionHandler: ((Bool) -> Void)? = nil) {}
    nonisolated public static let didBecomeActiveNotification = Notification.Name("UIApplicationDidBecomeActive")
    nonisolated public static let didEnterBackgroundNotification = Notification.Name("UIApplicationDidEnterBackground")
    nonisolated public static let willEnterForegroundNotification = Notification.Name("UIApplicationWillEnterForeground")
}

// Linux Foundation ships only the block-based observer API; the selector-based overload is
// Objective-C only. It is real and correct on Apple platforms, so the shim restores it —
// otherwise every call site would look like a bug when it is not.
extension NotificationCenter {
    public func addObserver(_ observer: Any, selector: Selector,
                            name: NSNotification.Name?, object: Any?) {}
}

// Apple's declaration, verified against developer.apple.com/documentation/uikit/uidevice:
//   @MainActor class UIDevice
@MainActor public final class UIDevice {
    public static var current: UIDevice { UIDevice() }
    public var systemVersion: String { "" }
    public var identifierForVendor: UUID? { nil }
}
