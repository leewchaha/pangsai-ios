import SwiftUI

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

    var body: some View {
        @Bindable var model = model
        ZStack(alignment: .bottom) {
            Group {
                switch model.tab {
                case .today: TodayView()
                case .map: PoopMapView()
                case .groups: GroupsView()
                case .calendar: CalendarScreen()
                case .you: YouView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 86) }

            VStack(spacing: 10) {
                if model.store.liveEvent != nil && !model.showSession && model.tab != .today {
                    LiveSessionBar()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                TabBar(selection: $model.tab)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
            .animation(Motion.bouncy, value: model.store.liveEvent?.id)
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
            SessionView()
                .environment(model)
        }
        .sheet(item: $model.sheet) { sheet in
            ActiveSheetView(sheet: sheet)
                .environment(model)
        }
        .background(Palette.paper.ignoresSafeArea())
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
        case .party(let id):
            NavigationStack { PartyDetailView(partyID: id) }
        case .highlights(let period, let date):
            HighlightsView(period: period, reference: date)
        }
    }
}

struct TabBar: View {
    @Binding var selection: AppTab

    private func color(_ tab: AppTab) -> Color {
        switch tab {
        case .today: return Palette.sun
        case .map: return Palette.aqua
        case .groups: return Palette.pink
        case .calendar: return Palette.lime
        case .you: return Palette.violet
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                let selected = tab == selection
                Button {
                    if !selected { Haptics.tick() }
                    withAnimation(Motion.snappy) { selection = tab }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: selected ? 21 : 18, weight: .black))
                        Text(tab.title)
                            .font(.heading(9))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    .foregroundStyle(selected ? (tab == .you || tab == .groups ? .white : Palette.inkFixed) : Palette.ink)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(color(tab))
                                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.line, lineWidth: 2))
                        }
                    }
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(tab.title.capitalized)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(6)
        .sticker(Palette.card, radius: 22, shadow: 4)
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
                HStack(spacing: 12) {
                    Object3DImage(subject: .poop(model.store.profile.equippedCosmetic), size: 34)
                    Text("CURRENTLY POOPING").font(.heading(13)).foregroundStyle(Palette.inkFixed)
                    Spacer()
                    TimerText(start: live.startedAt, size: 20, color: Palette.inkFixed)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .sticker(Palette.sun, radius: 18, shadow: 4)
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
