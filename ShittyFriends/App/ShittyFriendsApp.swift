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
                    RenderCache.shared.prewarm()
                    await delegate.model.start()
                }
                .onOpenURL { url in delegate.model.handle(url: url) }
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
