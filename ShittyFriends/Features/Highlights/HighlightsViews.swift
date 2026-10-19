import SwiftUI

/// Instagram-stories-style highlights. Tap right = next, tap left = back, hold = pause, swipe
/// left/right = next/back, swipe down = close. Cards auto-advance; the last page is the poster.
/// Personal by default (my poops only); pass `groupZone` for a group's own highlights.
struct HighlightsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var period: HighlightPeriod
    var reference: Date
    var groupZone: ZoneRef?

    @State private var index = 0
    /// 0...1 fill of the current story bar.
    @State private var progress: Double = 0
    /// Finger down on a card = paused. A GestureState, so a cancelled touch can't freeze the clock.
    @GestureState private var pressing = false
    @State private var pressStartedAt: Date?
    /// The share sheet for a card is open (or was): don't auto-advance underneath it.
    @State private var sharing = false
    /// Cards are computed once per opening: the clock re-renders the view 20×/s, and a sync landing
    /// mid-story must not reshuffle (or shrink) the pages under the user.
    @State private var frozenCards: [HighlightCard]?
    @GestureState(resetTransaction: Transaction(animation: Motion.snappy)) private var dragY: CGFloat = 0
    @State private var conclusionStyle: ConclusionPosterStyle = .random()

    /// Seconds each card stays up before auto-advancing.
    private static let cardDuration: Double = 5.5

    init(period: HighlightPeriod, reference: Date, groupZone: ZoneRef? = nil) {
        self.period = period
        self.reference = reference
        self.groupZone = groupZone
    }

    private var cards: [HighlightCard] { frozenCards ?? liveCards }

    private var liveCards: [HighlightCard] {
        if let z = groupZone { return model.store.groupHighlightCards(z, period: period, reference: reference) }
        return model.store.myHighlightCards(period: period, reference: reference)
    }

    private var scopeTitle: String {
        if let z = groupZone {
            return model.store.groupSummaries.first(where: { $0.link.zone == z })?.name.uppercased() ?? "GROUP"
        }
        return "@" + model.store.profile.handle.uppercased()
    }

    /// "OCT 6 – 12", "OCT 8", "OCTOBER 2026": which days this report covers.
    private var rangeLabel: String {
        let interval = period.interval(containing: reference, calendar: model.store.calendar)
        let start = interval.start
        let end = interval.end.addingTimeInterval(-1)
        switch period {
        case .day:
            return start.formatted(.dateTime.month(.abbreviated).day()).uppercased()
        case .week:
            return (start.formatted(.dateTime.month(.abbreviated).day()) + " – " + end.formatted(.dateTime.month(.abbreviated).day())).uppercased()
        case .month:
            return start.formatted(.dateTime.month(.wide).year()).uppercased()
        }
    }

    var body: some View {
        let cards = self.cards
        let slideCount = cards.isEmpty ? 0 : cards.count + 1
        let onPoster = index >= cards.count
        ZStack {
            background(cards: cards)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.45), value: index)
            VStack(spacing: 12) {
                if slideCount > 0 {
                    storyBars(count: slideCount)
                }
                header
                if cards.isEmpty {
                    Spacer()
                    EmptyState(emoji: "🦗", title: "NOTHING TO REPORT", message: "Quiet \(period == .day ? "day" : period == .week ? "week" : "month"). Suspiciously quiet.")
                        .sticker(.white)
                    Spacer()
                } else {
                    GeometryReader { geo in
                        let frame = geo.frame(in: .global)
                        slide(cards: cards)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .contentShape(Rectangle())
                            // Cards: the whole area is a story surface. Poster: only swipes, so its
                            // SHARE / SAVE / SHUFFLE buttons keep working.
                            .gesture(storyGesture(leftZoneEndX: frame.minX + frame.width * 0.33, slideCount: slideCount),
                                     including: onPoster ? .subviews : .all)
                            .simultaneousGesture(posterSwipe(slideCount: slideCount),
                                                 including: onPoster ? .all : .subviews)
                    }
                    if !onPoster {
                        ShareCardButton(card: cards[index], period: period)
                            .simultaneousGesture(TapGesture().onEnded { sharing = true })
                    }
                }
            }
            .gutter()
            .padding(.vertical, 12)
            .offset(y: dragY * 0.5)
        }
        .task(id: index) { await runStoryClock(cardCount: cards.count) }
        .onAppear { if frozenCards == nil { frozenCards = liveCards } }
        .onChange(of: pressing) { _, isDown in if isDown { pressStartedAt = Date() } }
        // Our own swipe-down closes it; the sheet must not also move with the same finger.
        .interactiveDismissDisabled(!cards.isEmpty)
        // Cards are fixed colours with dark ink; the final slide sits on paper. Keep it the light
        // paper in Dark Mode too, or the header and "nothing to report" text vanish.
        .environment(\.colorScheme, .light)
    }

    // MARK: Pieces

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(period.title).font(.heading(14)).foregroundStyle(Palette.inkFixed)
                Text(scopeTitle + " · " + rangeLabel)
                    .font(.heading(10))
                    .foregroundStyle(Palette.inkFixed.opacity(0.65))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 16, weight: .black)).foregroundStyle(Palette.inkFixed)
                    .frame(width: 40, height: 40).sticker(.white, radius: 14, shadow: 3)
            }
            .accessibilityLabel("Close")
        }
    }

    private func storyBars(count: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { i in
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.inkFixed.opacity(0.22))
                        Capsule()
                            .fill(Palette.inkFixed)
                            .frame(width: g.size.width * CGFloat(i < index ? 1 : (i == index ? progress : 0)))
                    }
                }
                .frame(height: 4)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Highlight \(min(index + 1, count)) of \(count)")
    }

    @ViewBuilder
    private func slide(cards: [HighlightCard]) -> some View {
        Group {
            if index < cards.count {
                HighlightCardView(card: cards[index], compact: false)
                    .padding(.vertical, 6)
            } else {
                let data = PosterBuilder.conclusionData(cards: cards, period: period, scopeTitle: scopeTitle, isGroup: groupZone != nil, rangeLabel: rangeLabel, store: model.store)
                PosterHost(title: "FINAL POSTER", exportID: "conclusion-\(scopeTitle)-\(period.rawValue)-\(conclusionStyle.rawValue)", poop: data.cosmetic, onShuffle: { conclusionStyle = .random(excluding: conclusionStyle) }) {
                    ConclusionPosterView(data: data, style: conclusionStyle)
                }
                .padding(.vertical, 6)
            }
        }
        // One view per page, so moving between pages (including into the poster's different
        // layout) cross-fades and settles instead of snapping.
        .id(index)
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.94)),
            removal: .opacity.combined(with: .scale(scale: 1.04))
        ))
    }

    @ViewBuilder
    private func background(cards: [HighlightCard]) -> some View {
        if index < cards.count {
            cards[index].color.color
        } else {
            Palette.paper
        }
    }

    // MARK: Navigation

    private func go(to newIndex: Int, slideCount: Int) {
        guard newIndex >= 0, newIndex < slideCount, newIndex != index else { return }
        Haptics.tick()
        progress = 0
        sharing = false
        withAnimation(.spring(response: 0.45, dampingFraction: 0.88)) {
            index = newIndex
        }
    }

    /// Tap left third = back, elsewhere = next. Hold = pause. Horizontal swipe = next/back.
    /// Swipe down = close.
    /// Global coordinates throughout: the content moves with the finger (swipe-down), so local
    /// coordinates would drift under it.
    private func storyGesture(leftZoneEndX: CGFloat, slideCount: Int) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .updating($pressing) { _, state, _ in state = true }
            .updating($dragY) { value, state, _ in
                let dy = value.translation.height
                state = (dy > 0 && abs(value.translation.width) < dy) ? dy : 0
            }
            .onEnded { value in
                let held = Date().timeIntervalSince(pressStartedAt ?? Date())
                pressStartedAt = nil
                let dx = value.translation.width
                let dy = value.translation.height
                if dy > 110, abs(dx) < dy {
                    dismiss()
                    return
                }
                if abs(dx) > 50, abs(dx) > abs(dy) {
                    go(to: dx < 0 ? index + 1 : index - 1, slideCount: slideCount)
                } else if held < 0.35, abs(dx) < 12, abs(dy) < 12 {
                    go(to: value.location.x < leftZoneEndX ? index - 1 : index + 1, slideCount: slideCount)
                }
            }
    }

    /// On the poster page only swipes navigate (taps belong to its buttons).
    private func posterSwipe(slideCount: Int) -> some Gesture {
        DragGesture(minimumDistance: 30, coordinateSpace: .global)
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                if dy > 110, abs(dx) < dy {
                    dismiss()
                } else if dx > 50, abs(dx) > abs(dy) {
                    go(to: index - 1, slideCount: slideCount)
                }
            }
    }

    /// Fills the current bar and advances when it's full. Paused while a finger is down.
    private func runStoryClock(cardCount: Int) async {
        guard index < cardCount else {
            progress = 1
            return
        }
        progress = 0
        let tick: Double = 0.05
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if Task.isCancelled { return }
            if pressing || sharing { continue }
            progress = min(1, progress + tick / HighlightsView.cardDuration)
            if progress >= 1 {
                go(to: index + 1, slideCount: cardCount + 1)
                return
            }
        }
    }
}

struct HighlightCardView: View {
    var card: HighlightCard
    var compact: Bool

    var body: some View {
        Group {
            if compact {
                HStack(alignment: .top, spacing: 10) {
                    Text(card.emoji)
                        .font(.system(size: 27))
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(card.color.color.opacity(0.28)))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(card.title)
                            .font(.heading(10))
                            .tracking(0.6)
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                        Text(card.headline)
                            .font(.display(20))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.55)
                        Text(card.detail)
                            .font(.ui(11, .semibold))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .calmSurface(Palette.card, radius: 18)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Text(card.emoji).font(.system(size: 90))
                    Text(card.title)
                        .font(.heading(20))
                        .tracking(1)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                    Text(card.headline)
                        .font(.display(54))
                        .lineLimit(2)
                        .minimumScaleFactor(0.4)
                    Text(card.detail)
                        .font(.ui(20, .bold))
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(card.color.ink)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(26)
                .sticker(card.color.color, radius: 34, shadow: 5)
            }
        }
    }
}

/// Renders the card to an image for sharing (Messages, LINE, Instagram stories…).
struct ShareCardButton: View {
    var card: HighlightCard
    var period: HighlightPeriod
    @State private var image: Image?

    var body: some View {
        Group {
            if let image {
                ShareLink(item: image, preview: SharePreview(card.title, image: image)) {
                    Label("SHARE CARD", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.sticker(.white, ink: Palette.inkFixed))
            } else {
                Color.clear.frame(height: 58)
            }
        }
        .task(id: card.id) { render() }
    }

    @MainActor private func render() {
        let content = VStack(alignment: .leading, spacing: 0) {
            HighlightCardView(card: card, compact: false)
                .frame(width: 360, height: 520)
            HStack {
                Text(period.title).font(.heading(12))
                Spacer()
                Text("SHITTYFRIENDS 💩").font(.heading(12))
            }
            .foregroundStyle(Palette.inkFixed)
            .padding(.top, 12)
        }
        .padding(24)
        .background(Palette.sun)
        .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 3
        if let ui = renderer.uiImage { image = Image(uiImage: ui) }
    }
}
