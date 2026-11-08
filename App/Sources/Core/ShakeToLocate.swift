import CoreGraphics
import Darwin

/// macOS "Shake mouse pointer to locate" (System Settings › Accessibility ›
/// Display › Pointer): moving the mouse quickly enlarges the pointer.
///
/// System Settings flips it through two SkyLight functions: one writes the
/// `CGDisableCursorLocationMagnification` global preference, then sends it to
/// the WindowServer, so it applies at once (a plain `defaults write` needs a
/// logout). They're private, so they're looked up at run time: if a future
/// macOS removes them, GameEdge simply leaves the setting alone.
enum ShakeToLocate {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SetDisabled = @convention(c) (Int32, Bool) -> Int32
    private typealias IsDisabled = @convention(c) () -> Bool

    private struct Functions {
        let mainConnection: MainConnection
        let setDisabled: SetDisabled
        let isDisabled: IsDisabled
    }

    private static let functions: Functions? = {
        guard let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let main = dlsym(skyLight, "SLSMainConnectionID"),
              let set = dlsym(skyLight, "SLSPackagesDisableFindCursor"),
              let get = dlsym(skyLight, "SLSPackagesFindCursorIsDisabled") else { return nil }
        return Functions(mainConnection: unsafeBitCast(main, to: MainConnection.self),
                         setDisabled: unsafeBitCast(set, to: SetDisabled.self),
                         isDisabled: unsafeBitCast(get, to: IsDisabled.self))
    }()

    static var isSupported: Bool { functions != nil }

    /// Whether shaking the mouse enlarges the pointer right now (nil if unknown).
    static var isEnabled: Bool? {
        functions.map { !$0.isDisabled() }
    }

    /// Turns the feature on or off for the whole Mac, immediately.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        guard let functions else { return false }
        _ = functions.setDisabled(functions.mainConnection(), !enabled)
        return functions.isDisabled() == !enabled
    }
}
