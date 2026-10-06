import SwiftUI

/// Full-screen live timed session: timer, the big tappable 3D poop, Poop With Me, DONE.
struct SessionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var completed: PoopEvent?
    @State private var showPicker = false
    @State private var showLocationAsk = false
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
            if let done = completed {
                DoneCard(event: done) { dismiss() }
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else if let live = store.liveEvent {
                live_(live)
            } else {
                Color.clear.onAppear { dismiss() }
            }
            ConfettiBurst(trigger: confetti)
                .allowsHitTesting(false)
        }
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

    // MARK: Live

    private func live_(_ live: PoopEvent) -> some View {
        VStack(spacing: 0) {
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
        }
    }

    private func topBar(_ live: PoopEvent) -> some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(Palette.inkFixed)
                    .frame(width: 46, height: 46)
                    .sticker(.white, radius: 16, shadow: 3)
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Minimize")
            Spacer()
            Button {
                if live.location != nil { return }
                if model.location.isAuthorized {
                    attachLocation(live.id)
                } else {
                    showLocationAsk = true
                }
            } label: {
                Text(live.location.map { "📍 " + $0.label } ?? "📍 ADD LOCATION")
                    .font(.heading(12))
                    .foregroundStyle(Palette.inkFixed)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .sticker(.white, radius: 14, shadow: 3)
            }
            .buttonStyle(PressableStyle())
        }
        .gutter()
        .padding(.top, 6)
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
            text = o.dailyCapped ? "DAILY CAP" : (o.sessionCapped ? "CAPPED" : "·")
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

    private func formatHalf(_ half: Int) -> String {
        half % 2 == 0 ? "\(half / 2)" : (half == 1 ? "½" : "\(half / 2)½")
    }

    private func pointsLine(_ live: PoopEvent) -> some View {
        let last = store.lastTap
        return VStack(spacing: 4) {
            Text("+\(formatHalf(live.halfPoints)) POINTS THIS SESSION")
                .font(.heading(16))
                .foregroundStyle(Palette.inkFixed)
                .contentTransition(.numericText(value: live.points))
                .animation(Motion.snappy, value: live.halfPoints)
            if let l = last, l.combo >= 5 {
                Text("COMBO ×\(l.combo)")
                    .font(.display(CGFloat(16 + 3 * l.comboLevel)))
                    .foregroundStyle([Palette.pink, Palette.blue, Palette.violet, Palette.tomato, Palette.tangerine, Palette.inkFixed][min(5, l.comboLevel)])
                    .rotationEffect(.degrees(Double(l.combo % 2 == 0 ? -3 : 3)))
                    .animation(Motion.slam, value: l.combo)
            } else if live.taps == 0 {
                Text("tap tap tap tap tap")
                    .font(.ui(14, .bold))
                    .foregroundStyle(Palette.inkFixed.opacity(0.6))
            }
            if last?.sessionCapped == true {
                Text("Session cap reached. Respect.")
                    .font(.ui(13, .semibold))
                    .foregroundStyle(Palette.inkFixed.opacity(0.7))
            }
        }
        .padding(.vertical, 10)
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
        VStack(spacing: 14) {
            Spacer()
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
                stat("+\(Int(event.points.rounded(.down)))", "POINTS")
                stat("\(model.store.pointsBalance)", "BALANCE")
            }
            .padding(.top, 8)
            if let sid = event.pwmSessionID, let v = model.store.liveSession(sid) {
                let others = v.participants.filter { $0.id != model.store.userID && ($0.status == .joined || $0.status == .done) }
                if !others.isEmpty {
                    Text("WITH " + others.map { "@" + $0.person.handle }.joined(separator: ", ").uppercased())
                        .font(.heading(13))
                        .foregroundStyle(Palette.inkFixed)
                }
            }
            Spacer()
            Button("NICE", action: close)
                .buttonStyle(.sticker(Palette.sun, height: 64))
                .gutter()
                .padding(.bottom, 24)
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.digits(24)).foregroundStyle(Palette.inkFixed)
            Text(label).font(.heading(10)).foregroundStyle(Palette.inkFixed.opacity(0.7))
        }
        .frame(width: 96, height: 72)
        .sticker(.white, radius: 16, shadow: 3)
    }
}

// MARK: - Location ask (first use)

struct LocationAskView: View {
    @Environment(AppModel.self) private var model
    var done: (Bool) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("📍").font(.system(size: 54))
            Text("ADD WHERE YOU POOP?").font(.display(24)).multilineTextAlignment(.center)
            Text("ShittyFriends can attach your location to a poop so friends can see where it happened. Only when you ask — never in the background.")
                .font(.ui(15, .medium))
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
            Button("ALLOW LOCATION") {
                Task {
                    let ok = await model.location.requestAuthorization()
                    model.store.updateSettings { $0.locationPrompted = true }
                    done(ok)
                }
            }
            .buttonStyle(.sticker(Palette.aqua))
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
