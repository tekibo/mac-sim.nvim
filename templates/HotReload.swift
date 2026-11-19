import SwiftUI
#if DEBUG
import Foundation

private let didLoadBundle: Void = {
    guard let hostHome = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] else { return }
    let bundlePath = "\(hostHome)/.mac-sim/bundles/iOSInjection.bundle"
    if let bundle = Bundle(path: bundlePath), bundle.load() {
        print("[mac-sim] In-process hot reload active from \(bundlePath)")
    }
}()

public struct HotReloadRootModifier: ViewModifier {
    @State private var reloadID = 0

    public func body(content: Content) -> some View {
        _ = didLoadBundle
        return content
            .id(reloadID)
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("INJECTION_BUNDLE_NOTIFICATION"))) { _ in
                reloadID += 1
            }
    }
}
#endif

extension View {
    @ViewBuilder
    public func enableHotReload() -> some View {
        #if DEBUG
        self.modifier(HotReloadRootModifier())
        #else
        self
        #endif
    }

    #if DEBUG
    @inline(__always)
    public func eraseToAnyView() -> AnyView {
        AnyView(self)
    }
    #else
    @inlinable
    @inline(__always)
    public func eraseToAnyView() -> Self {
        self
    }
    #endif
}
