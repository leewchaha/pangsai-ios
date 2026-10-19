import SwiftUI

/// Full-screen live timed session: timer, the big tappable 3D poop, Poop With Me, DONE.
struct SessionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var completed: PoopEvent?
    @State private var showPicker = false
    @State private var showLocationAsk = false
    /// Swipe-down-to-hide: live drag distance and whether the content is scrolled to the top.
    /// Visual offset; a GestureState so a cancelled drag (scroll view takeover) never leaves it stuck.
    @GestureState(resetTransaction: Transaction(animation: Motion.snappy)) private var dragY: CGFloat = 0
    @State private var scrollAtTop = true
    /// Drag translation at the moment the content was at the top; the hide distance counts from
    /// here, so scrolling back up in the same drag doesn't jump straight into a hide.
    @State private var topBaseline: CGFloat?
    @State private var pops: [TapPop] = []
    @State private var confetti = 0

    private var store: Store { model.store }

    var body: some View {
        let color = store.profile.color
        ZStack {
            LinearGradient(colors: [color.color, color.color.opacity(0.55), Palette.paper], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            BlobBackground(colors: [Palette.sun, color.color, Palette.pink], intensity: 0.25)
                .opacity(0.6)
            Group {
                if let done = completed {
                    DoneCard(event: done) { dismiss() }
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                } else if let live = store.liveEvent {
                    live_(live)
                } else {
                    Color.clear.onAppear { dismiss() }
                }
            }
            .offset(y: dragY * 0.6)
            .opacity(1 - min(0.35, Double(dragY) / 600))
            ConfettiBurst(trigger: confetti)
                .allowsHitTesting(false)
        }
        .scaleEffect(1 - min(0.06, dragY / 3000))
        .simultaneousGesture(swipeDownToHide)
        .overlay(alignment: .top) { ToastStack().padding(.top, 6) }
        .sheet(isPresented: $showPicker) {
            PWMPickerView(existing: store.liveEvent?.pwmSessionID.flatMap { store.liveSession($0) })
                .environment(model)
        }
        .sheet(isPresented: $showLocationAsk) {
            LocationAskView { allowed in
                showLocationAsk = false
                if allowed, let id = store.liveEvent?.id { attachLocation(id) }
            }
            .environment(model)
            .presentationDetents([.medium])
        }
        .onChange(of: model.openPWM) { _, new in if new != nil { model.openPWM = nil } }
    }

    /// Swipe down anywhere (when not scrolled) to hide the session; the timer keeps running.
    private var swipeDownToHide: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .global)
            .updating($dragY) { value, state, _ in
                guard let base = topBaseline else { state = 0; return }
                let dy = value.translation.height - base
                state = (dy > 0 && abs(value.translation.width) < value.translation.height) ? dy : 0
            }
            .onChanged { value in
                let atTop = scrollAtTop || completed != nil
                if !atTop {
                    topBaseline = nil
                } else if topBaseline == nil || value.translation.height < (topBaseline ?? 0) {
                    // First moment at the top in this drag (or a stale value from a cancelled one).
                    topBaseline = max(0, value.translation.height)
                }
            }
            .onEnded { value in
                defer { topBaseline = nil }
                guard let base = topBaseline else { return }
                let dy = value.translation.height - base
                let downward = dy > 0 && abs(value.translation.width) < value.translation.height
                if downward && (dy > 130 || value.predictedEndTranslation.height - base > 320) {
                    Haptics.tick()
                    dismiss()
                }
            }
    }

    // MARK: Live

    private func live_(_ live: PoopEvent) -> some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Palette.inkFixed.opacity(0.28))
                .frame(width: 40, height: 5)
                .padding(.top, 6)
                .accessibilityHidden(true)
            topBar(live)
            ScrollView {
                VStack(spacing: 14) {
                    VStack(spacing: 2) {
                        Text("CURRENTLY POOPING")
                            .font(.display(26))
                            .foregroundStyle(store.profile.color.ink)
                        Text(Copy.sessionStarted(seed: Copy.seed(live.id)))
                            .font(.ui(15, .semibold))
                            .foregroundStyle(store.profile.color.ink.opacity(0.75))
                    }
                    TimerText(start: live.startedAt, size: 72, color: store.profile.color.ink)
                    longSessionNote(live)
                    tapArea(live)
                    pointsLine(live)
                    if let sid = live.pwmSessionID, let view = store.liveSession(sid) {
                        PWMLivePanel(view: view) { showPicker = true }
                    } else {
                        Button {
                            showPicker = true
                        } label: {
                            Label("POOP WITH ME", systemImage: "person.2.fill")
                        }
                        .buttonStyle(.sticker(Palette.pink, ink: .white, height: 60))
                    }
                    Button {
                        finish(live)
                    } label: {
                        Text("DONE")
                    }
                    .buttonStyle(StickerButtonStyle(fill: Palette.lime, ink: Palette.inkFixed, radius: 26, height: 76, font: .display(30)))
                    .padding(.top, 4)
                }
                .gutter()
                .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y + geo.contentInsets.top <= 1
            } action: { _, atTop in
                scrollAtTop = atTop
            }
        }
    }

    private func topBar(_ live: PoopEvent) -> some View {
        HStack {
            Button { dismiss() } label: {
                // Also: swipe down anywhere.
                Image(systemName: "chevron.down")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(Palette.inkFixed)
                    .frame(width: 46, height: 46)
                    .sticker(.white, radius: 16, shadow: 3)
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Minimize")
            Spacer()
            undoPill(live)
            Spacer()
            // Every poop is pinned. The chip only shows where; when the fix is missing (no permission,
            // no signal) tapping it tries again.
            Button {
                guard live.location == nil else { return }
                if model.location.isAuthorized {
                    attachLocation(live.id)
                } else {
                    showLocationAsk = true
                }
            } label: {
                Text(live.location.map { "📍 " + $0.label } ?? "📍 ADD LOCATION")
                    .lineLimit(1)
                    .font(.heading(12))
                    .foregroundStyle(Palette.inkFixed)
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .sticker(.white, radius: 14, shadow: 3)
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(live.location.map { "Location \($0.label)" } ?? "Add location")
        }
        .gutter()
        .padding(.top, 6)
    }

    /// Short-lived Undo right after starting (mis-taps happen). Deletes the poop entirely.
    private func undoPill(_ live: PoopEvent) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            if let u = store.undo, u.eventID == live.id, ctx.date.timeIntervalSince(u.at) < Store.undoWindow {
                Button {
                    store.performUndo()
                    Haptics.play(.warning)
                    dismiss()
                } label: {
                    Text("↩︎ UNDO")
                        .font(.heading(12))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 40)
                        .sticker(Palette.inkFixed, radius: 14, shadow: 3)
                }
                .buttonStyle(PressableStyle())
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel("Undo, didn't mean to start")
            }
        }
    }

    private func attachLocation(_ id: UUID) {
        model.location.locateOnce { loc in
            if let loc { model.store.attachLocation(loc, to: id) } else { model.info("NO LOCATION", "Couldn't get a fix. You can add it later from the calendar.") }
        }
    }

    @ViewBuilder private func longSessionNote(_ live: PoopEvent) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            let elapsed = ctx.date.timeIntervalSince(live.startedAt)
            if elapsed > 30 * 60 {
                Text(elapsed > PoopEvent.suspiciousDuration ? "STILL POOPING? It's been a while. Tap DONE — you can fix the time later." : "STILL POOPING? No judgment.")
                    .font(.ui(14, .bold))
                    .foregroundStyle(Palette.inkFixed)
                    .multilineTextAlignment(.center)
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .sticker(Palette.sun, radius: 16, shadow: 3)
            }
        }
    }

    // MARK: Tapping

    private func tapArea(_ live: PoopEvent) -> some View {
        let last = store.lastTap
        return ZStack {
            PoopStageView(cosmetic: store.profile.equippedCosmetic, pulse: store.tapPulse, comboLevel: last?.comboLevel ?? 0, critical: last?.isCritical ?? false)
                .frame(height: 300)
            ForEach(pops) { pop in
                TapPopView(pop: pop)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .gesture(
            SpatialTapGesture().onEnded { value in
                guard let outcome = store.tapPoop() else { return }
                addPop(outcome, at: value.location)
            }
        )
        .accessibilityElement()
        .accessibilityLabel("Poop. Tap to earn points.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if let o = store.tapPoop() { addPop(o, at: CGPoint(x: 180, y: 150)) } }
    }

    private func addPop(_ o: TapOutcome, at point: CGPoint) {
        let text: String
        if o.gainedHalfPoints == 0 {
            text = "·" // too fast (auto-clicker guard): animates, earns nothing
        } else if o.isCritical {
            text = "CRIT! +\(formatHalf(o.gainedHalfPoints))"
        } else {
            text = "+\(formatHalf(o.gainedHalfPoints))"
        }
        let pop = TapPop(text: text, origin: point, critical: o.isCritical, level: o.comboLevel)
        pops.append(pop)
        if o.isCritical || (o.combo > 0 && o.combo % 20 == 0) { confetti += 1 }
        let id = pop.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            pops.removeAll { $0.id == id }
        }
    }

    private func formatHalf(_ half: Int) -> String { formatHalfPoints(half) }

    /// Session points. Uncapped: every tap pays for as long as the timer runs.
    private func pointsLine(_ live: PoopEvent) -> some View {
        let last = store.lastTap
        return VStack(spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("+\(formatHalf(live.halfPoints)) PTS")
                    .font(.heading(16))
                    .foregroundStyle(Palette.inkFixed)
                    .contentTransition(.numericText(value: live.points))
                    .animation(Motion.snappy, value: live.halfPoints)
                Text("THIS POOP")
                    .font(.heading(10))
                    .foregroundStyle(Palette.inkFixed.opacity(0.6))
                Spacer()
                Text("BALANCE \(formatPoints(store.pointsBalance))")
                    .font(.heading(10))
                    .foregroundStyle(Palette.inkFixed.opacity(0.65))
                    .contentTransition(.numericText(value: Double(store.pointsBalance)))
            }
            if let l = last, l.combo >= 5 {
                Text("COMBO ×\(l.combo)")
                    .font(.display(CGFloat(16 + 3 * l.comboLevel)))
                    .foregroundStyle([Palette.pink, Palette.blue, Palette.violet, Palette.tomato, Palette.tangerine, Palette.inkFixed][min(5, l.comboLevel)])
                    .rotationEffect(.degrees(Double(l.combo % 2 == 0 ? -3 : 3)))
                    .animation(Motion.slam, value: l.combo)
            } else if live.taps == 0 {
                Text("Tap the poop. Every tap pays, no limit.")
                    .font(.ui(13, .bold))
                    .foregroundStyle(Palette.inkFixed.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .sticker(.white, radius: 18, shadow: 3)
    }

    private func finish(_ live: PoopEvent) {
        let id = live.id
        store.finish(id)
        confetti += 1
        withAnimation(Motion.bouncy) { completed = store.my.events[id] }
    }
}

/// "3", "½", "3½" from half-point units.
func formatHalfPoints(_ half: Int) -> String {
    half % 2 == 0 ? "\(half / 2)" : (half == 1 ? "½" : "\(half / 2)½")
}

// MARK: - Tap pops

struct TapPop: Identifiable {
    let id = UUID()
    var text: String
    var origin: CGPoint
    var critical: Bool
    var level: Int
    let drift = CGFloat.random(in: -40...40)
}

struct TapPopView: View {
    var pop: TapPop
    @State private var go = false

    var body: some View {
        Text(pop.text)
            .font(.display(pop.critical ? 30 : 20 + CGFloat(pop.level) * 2))
            .foregroundStyle(pop.critical ? Palette.tomato : Palette.inkFixed)
            .shadow(color: .white, radius: 0, x: 2, y: 2)
            .scaleEffect(go ? 1.15 : 0.4)
            .opacity(go ? 0 : 1)
            .position(x: pop.origin.x + (go ? pop.drift : 0), y: pop.origin.y - (go ? 110 : 0))
            .onAppear { withAnimation(.easeOut(duration: 0.85)) { go = true } }
            .allowsHitTesting(false)
    }
}

/// Emoji confetti for criticals, milestones and DONE.
struct ConfettiBurst: View {
    var trigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pieces: [Piece] = []

    struct Piece: Identifiable {
        let id = UUID()
        var emoji: String
        var dx: CGFloat
        var dy: CGFloat
        var spin: Double
        var fired = false
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(pieces) { p in
                    Text(p.emoji)
                        .font(.system(size: 30))
                        .rotationEffect(.degrees(p.fired ? p.spin : 0))
                        .position(x: geo.size.width / 2 + (p.fired ? p.dx : 0), y: geo.size.height * 0.45 + (p.fired ? p.dy : 0))
                        .opacity(p.fired ? 0 : 1)
                }
            }
        }
        .onChange(of: trigger) { _, _ in
            guard !reduceMotion else { return }
            let emojis = ["💩", "✨", "🧻", "⭐️", "💥", "👑"]
            let new = (0..<16).map { _ in Piece(emoji: emojis.randomElement()!, dx: .random(in: -220...220), dy: .random(in: -420...160), spin: .random(in: -540...540)) }
            pieces.append(contentsOf: new)
            let ids = Set(new.map(\.id))
            withAnimation(.easeOut(duration: 1.3)) {
                for i in pieces.indices where ids.contains(pieces[i].id) { pieces[i].fired = true }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                pieces.removeAll { ids.contains($0.id) }
            }
        }
    }
}

// MARK: - Done

struct DoneCard: View {
    @Environment(AppModel.self) private var model
    var event: PoopEvent
    var close: () -> Void

    var body: some View {
        let d = event.duration ?? 0
        VStack(spacing: 0) {
            ScrollView {
                content(d)
                    .padding(.top, 48)
                    .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
            Button("NICE", action: close)
                .buttonStyle(.sticker(Palette.sun, height: 64))
                .gutter()
                .padding(.bottom, 24)
        }
    }

    @ViewBuilder private func content(_ d: TimeInterval) -> some View {
        VStack(spacing: 14) {
            Object3DImage(subject: .poop(model.store.profile.equippedCosmetic), size: 150)
            Text("POOP COMPLETE")
                .font(.display(30))
                .foregroundStyle(Palette.inkFixed)
            Text(StatsCalculator.formatDuration(d))
                .font(.digits(72))
                .foregroundStyle(Palette.inkFixed)
            Text(Copy.sessionComplete(duration: d, seed: Copy.seed(event.id)))
                .font(.heading(18))
                .foregroundStyle(Palette.inkFixed.opacity(0.8))
            HStack(spacing: 12) {
                stat("\(model.store.todayCount())", "TODAY")
                stat("+" + formatHalfPoints(event.halfPoints), "POINTS")
                stat(formatPoints(model.store.pointsBalance), "BALANCE")
            }
            .padding(.top, 8)
            if let sid = event.pwmSessionID, let v = model.store.liveSession(sid) {
                let labels = model.store.labels(in: v.zone)
                let others = v.participants.filter { $0.id != model.store.userID && ($0.status == .joined || $0.status == .done) }
                if !others.isEmpty {
                    Text("WITH " + others.map { labels[$0.id] ?? "@" + $0.person.handle }.joined(separator: ", ").uppercased())
                        .font(.heading(13))
                        .foregroundStyle(Palette.inkFixed)
                }
                if v.participants.contains(where: { $0.status == .joined }) {
                    // Others are still going: keep watching and reacting from here.
                    PWMLivePanel(view: v, inviteMore: nil)
                        .gutter()
                }
            } else if let sid = event.pwmSessionID, let archived = model.store.my.pwmArchive[sid] {
                let others = archived.participants.filter { $0.id != model.store.userID }
                if !others.isEmpty {
                    Text("WITH " + others.map { "@" + $0.handle }.joined(separator: ", ").uppercased())
                        .font(.heading(13))
                        .foregroundStyle(Palette.inkFixed)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.digits(24)).foregroundStyle(Palette.inkFixed)
            Text(label).font(.heading(10)).foregroundStyle(Palette.inkFixed.opacity(0.7))
        }
        .frame(width: 96, height: 72)
        .sticker(.white, radius: 16, shadow: 3)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Location ask (first use)

struct LocationAskView: View {
    @Environment(AppModel.self) private var model
    var done: (Bool) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("📍").font(.system(size: 54))
            Text("PIN THIS POOP?").font(.display(24)).multilineTextAlignment(.center)
            Text(model.location.isDenied
                 ? "Location is turned off for ShittyFriends in iOS Settings, so this poop can't get a pin. Turn it back on there."
                 : "Every poop gets a pin on the map — that's the app. Location is read once per poop, never in the background.")
                .font(.ui(15, .medium))
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
            if model.location.isDenied {
                OpenSystemSettingsButton(title: "OPEN iOS SETTINGS")
                    .buttonStyle(.sticker(Palette.aqua))
            } else {
                Button("ALLOW LOCATION") {
                    Task {
                        let ok = await model.location.requestAuthorization()
                        model.store.updateSettings { $0.locationPrompted = true }
                        done(ok)
                    }
                }
                .buttonStyle(.sticker(Palette.aqua))
            }
            Button("NOT NOW") {
                model.store.updateSettings { $0.locationPrompted = true }
                done(false)
            }
            .font(.heading(14))
            .foregroundStyle(Palette.ink)
        }
        .foregroundStyle(Palette.ink)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.paper.ignoresSafeArea())
    }
}
