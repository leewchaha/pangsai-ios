import SwiftUI
import MapKit

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.store.my.onboarded {
                MainShell()
            } else {
                OnboardingFlow()
            }
        }
        .preferredColorScheme(nil)
    }
}

/// Tabs + global overlays (toasts, busy indicator, live-session bar) + global sheets.
struct MainShell: View {
    @Environment(AppModel.self) private var model
    @State private var bottomChromeHeight: CGFloat = 72
    @State private var homeCamera: MapCameraPosition = .automatic
    @State private var homeCameraInitialized = false

    var body: some View {
        @Bindable var model = model
        ZStack(alignment: .bottom) {
            Group {
                switch model.tab {
                case .home: HomeView(position: $homeCamera, cameraInitialized: $homeCameraInitialized)
                case .groups: GroupsView()
                case .calendar: CalendarScreen()
                case .you: YouView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Every tab screen reads the ACTUAL size of the floating chrome (including the temporary
            // live-session banner) and reserves it on its own scroll views via `.clearsTabBar()`.
            .environment(\.tabBarClearance, bottomChromeHeight + 12)

            VStack(spacing: 10) {
                if model.store.liveEvent != nil && !model.showSession && model.tab != .home {
                    LiveSessionBar()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                TabBar(selection: $model.tab)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: FloatingChromeHeightKey.self, value: geometry.size.height)
                }
            }
            .animation(Motion.bouncy, value: model.store.liveEvent?.id)
        }
        .onPreferenceChange(FloatingChromeHeightKey.self) { newHeight in
            if newHeight > 0 && abs(bottomChromeHeight - newHeight) > 0.5 {
                bottomChromeHeight = newHeight
            }
        }
        .overlay(alignment: .top) {
            ToastStack().padding(.top, 6)
        }
        .overlay {
            if let busy = model.busy {
                BusyOverlay(text: busy).transition(.opacity)
            }
        }
        .fullScreenCover(isPresented: $model.showSession) {
            // The session is a fixed "sticker world" (identity colour → light paper): keep its
            // ink-on-colour contrast in Dark Mode too.
            SessionView()
                .environment(model)
                .environment(\.colorScheme, .light)
        }
        .sheet(item: $model.sheet) { sheet in
            ActiveSheetView(sheet: sheet)
                .environment(model)
        }
        .background(Palette.paper.ignoresSafeArea())
    }
}

private struct FloatingChromeHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 72 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct ActiveSheetView: View {
    @Environment(AppModel.self) private var model
    var sheet: ActiveSheet

    var body: some View {
        switch sheet {
        case .friendInvite(let payload):
            FriendInviteConfirmView(invite: payload)
        case .groupJoin(let id):
            if let offer = model.groupOffers[id] {
                GroupJoinConfirmView(offer: offer)
            } else {
                EmptyState(emoji: "🤷", title: "INVITE EXPIRED", message: "Open the link again.")
            }
        case .pwmInvite(let sid):
            PWMInviteView(sessionID: sid)
        case .pwmWatch(let sid):
            PWMWatchView(sessionID: sid)
        case .party(let id):
            NavigationStack { PartyDetailView(partyID: id) }
        case .highlights(let period, let date):
            HighlightsView(period: period, reference: date)
        case .groupHighlights(let zone):
            HighlightsView(period: .week, reference: Date().addingTimeInterval(-7 * 24 * 3600), groupZone: zone)
        case .profilePoster:
            ProfilePosterSheetView()
        }
    }
}

struct TabBar: View {
    @Binding var selection: AppTab

    private func color(_ tab: AppTab) -> Color {
        switch tab {
        case .home: return Palette.aqua
        case .groups: return Palette.pink
        case .calendar: return Palette.lime
        case .you: return Palette.violet
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                let selected = tab == selection
                Button {
                    if !selected { Haptics.tick() }
                    withAnimation(Motion.snappy) { selection = tab }
                } label: {
                    VStack(spacing: 3) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: tab.symbol)
                                .font(.system(size: 19, weight: .black))
                            if selected {
                                Circle()
                                    .fill(color(tab))
                                    .frame(width: 7, height: 7)
                                    .overlay(Circle().strokeBorder(Palette.paper, lineWidth: 1))
                                    .offset(x: 7, y: -4)
                            }
                        }
                        Text(tab.title)
                            .font(.heading(9.5))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    .foregroundStyle(selected ? Palette.paper : Palette.muted)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Palette.ink)
                        }
                    }
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(tab.title.capitalized)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(5)
        .background(
            RoundedRectangle(cornerRadius: 21, style: .continuous)
                .fill(Palette.card)
                .overlay(RoundedRectangle(cornerRadius: 21, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        )
    }
}

/// Shown on other tabs while a timed session is running.
struct LiveSessionBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let live = model.store.liveEvent {
            Button {
                model.showSession = true
            } label: {
                HStack(spacing: 10) {
                    Circle().fill(Palette.sun).frame(width: 10, height: 10)
                    Text("CURRENTLY POOPING").font(.heading(12)).foregroundStyle(Palette.paper)
                    Spacer()
                    TimerText(start: live.startedAt, size: 18, color: Palette.paper)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(Capsule().fill(Palette.ink))
            }
            .buttonStyle(PressableStyle())
        }
    }
}

struct BusyOverlay: View {
    var text: String
    @State private var spin = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 14) {
                Text("💩")
                    .font(.system(size: 46))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: spin)
                Text(text.uppercased()).font(.heading(15)).foregroundStyle(Palette.inkFixed)
            }
            .padding(28)
            .sticker(Palette.sun)
        }
        .onAppear { spin = true }
    }
}
