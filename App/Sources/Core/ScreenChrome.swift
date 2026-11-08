import CoreFoundation
import Darwin
import Foundation

/// The menu bar and the Dock, hidden while a game runs so a game in Windowed
/// mode can fill the whole display (macOS resizes windows to the space they leave).
enum ScreenChrome {
    // MARK: Menu bar ("Automatically hide and show the menu bar: Always")

    private static let menuBarKey = "_HIHideMenuBar" as CFString

    static var menuBarAutoHides: Bool {
        CFPreferencesCopyValue(menuBarKey, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            as? Bool ?? false
    }

    /// Applies at once: apps re-read the setting on this distributed notification.
    static func setMenuBarAutoHides(_ hides: Bool) {
        CFPreferencesSetValue(menuBarKey, hides as CFBoolean, kCFPreferencesAnyApplication,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        DistributedNotificationCenter.default().postNotificationName(
            .init("AppleInterfaceMenuBarHidingChangedNotification"), object: nil, userInfo: nil, deliverImmediately: true)
    }

    // MARK: Dock auto-hide

    // CoreDock (HIServices) is what System Settings uses: the Dock follows at
    // once, without restarting it. Private, so looked up at run time.
    private typealias GetAutoHide = @convention(c) () -> Bool
    private typealias SetAutoHide = @convention(c) (Bool) -> Void

    private static let dock: (get: GetAutoHide, set: SetAutoHide)? = {
        let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices", RTLD_LAZY)
        guard let get = dlsym(handle, "CoreDockGetAutoHideEnabled"),
              let set = dlsym(handle, "CoreDockSetAutoHideEnabled") else { return nil }
        return (unsafeBitCast(get, to: GetAutoHide.self), unsafeBitCast(set, to: SetAutoHide.self))
    }()

    static var canChangeDock: Bool { dock != nil }

    static var dockAutoHides: Bool { dock?.get() ?? true }

    static func setDockAutoHides(_ hides: Bool) {
        dock?.set(hides)
    }
}
