import SwiftUI

@main
struct SillApp: App {
    /// Only `buildMenu(with:)`: the Mac's menus in the iPad's menu bar on iPadOS 26 (SillAppDelegate).
    @UIApplicationDelegateAdaptor(SillAppDelegate.self) var appDelegate

    /// GameController reports an attached keyboard a moment after launch, and Immersive (and so the
    /// first viewport's `deviceDesktop` flag and panel size) depends on it: listening from here, not
    /// from the first stream screen, lets a connection made right at launch already know.
    init() { _ = HardwareKeyboardMonitor.shared }

    var body: some Scene {
        WindowGroup {
            // iOS 27.1 on the iPhone Duo: the hinge for the layouts (DuoPostureReader); nothing
            // before iOS 27.1 or on a device without a hinge.
            ContentView()
                .readsDuoPosture()
        }
    }
}
