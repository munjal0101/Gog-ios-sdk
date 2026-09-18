// Shim of the CoreGraphics/QuartzCore surface the GOG SDK touches.
// Signatures mirror Apple's; bodies are stubs. Purpose is TYPE CHECKING ONLY.
@_exported import Foundation

public final class CGColor: @unchecked Sendable { public init() {} }
public final class CGPath: @unchecked Sendable { public init() {} }

@MainActor open class CALayer {
    public init() {}
    open var cornerRadius: CGFloat = 0
    open var backgroundColor: CGColor?
    open func addSublayer(_ layer: CALayer) {}
}

@MainActor public final class CAShapeLayer: CALayer {
    public var fillColor: CGColor?
    public var strokeColor: CGColor?
    public var lineWidth: CGFloat = 1
    public var lineCap: CAShapeLayerLineCap = .butt
    public var path: CGPath?
    public var strokeEnd: CGFloat = 1
}

public struct CAShapeLayerLineCap: Hashable, Sendable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let butt = CAShapeLayerLineCap(rawValue: "butt")
    public static let round = CAShapeLayerLineCap(rawValue: "round")
    public static let square = CAShapeLayerLineCap(rawValue: "square")
}

public enum CATransaction {
    public static func begin() {}
    public static func commit() {}
    public static func setDisableActions(_ flag: Bool) {}
}
