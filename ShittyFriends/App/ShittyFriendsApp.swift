import SwiftUI

@main
struct ShittyFriendsApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(delegate.model)
                .task {
                    // Let SwiftUI + MapKit commit the first visible frame before starting CloudKit.
                    // The old launch path kicked CloudKit and a full 3D prewarm at the same time as
                    // the first screen, which made cold launch visibly hitch.  Cached data is already
                    // available synchronously, so a tiny delay costs nothing perceptible to the user.
                    await Task.yield()
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    await delegate.model.start()
                }
                .onOpenURL { url in
                    if url.scheme == "shittyfriends", url.host == "open-session" {
                        delegate.model.showSession = delegate.model.store.liveEvent != nil
                    } else {
                        delegate.model.handle(url: url)
                    }
                }
                .tint(Palette.ink)
        }
        .onChange(of: phase) { _, newPhase in
            switch newPhase {
            case .active: delegate.model.enteredForeground()
            case .background: delegate.model.enteredBackground()
            default: break
            }
        }
    }
}
