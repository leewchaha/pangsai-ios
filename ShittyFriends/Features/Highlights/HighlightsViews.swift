import SwiftUI

/// Spotify-Wrapped-style paced cards (own visuals). Swipe through; share any card as an image.
struct HighlightsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var period: HighlightPeriod
    var reference: Date
    @State private var index = 0
    @State private var scope: Scope

    init(period: HighlightPeriod, reference: Date, groupZone: ZoneRef? = nil) {
        self.period = period
        self.reference = reference
        _scope = State(initialValue: groupZone.map { Scope.group($0) } ?? .friends)
    }

    enum Scope: Hashable { case friends, group(ZoneRef) }

    private var cards: [HighlightCard] {
        switch scope {
        case .friends: return model.store.highlightCards(period: period, reference: reference)
        case .group(let z): return model.store.groupHighlightCards(z, period: period, reference: reference)
        }
    }

    var body: some View {
        let cards = self.cards
        ZStack {
            (cards.indices.contains(index) ? cards[index].color.color : Palette.sun)
                .ignoresSafeArea()
                .animation(Motion.soft, value: index)
            VStack(spacing: 14) {
                HStack {
                    Text(period.title).font(.heading(14)).foregroundStyle(Palette.inkFixed)
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 16, weight: .black)).foregroundStyle(Palette.inkFixed)
                            .frame(width: 40, height: 40).sticker(.white, radius: 14, shadow: 3)
                    }
                    .accessibilityLabel("Close")
                }
                if !model.store.groupSummaries.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            Button { scope = .friends; index = 0 } label: { Chip(text: "ME + FRIENDS", fill: .white, ink: Palette.inkFixed, selected: scope == .friends) }
                            ForEach(model.store.groupSummaries) { g in
                                Button { scope = .group(g.link.zone); index = 0 } label: { Chip(text: g.name.uppercased(), fill: .white, ink: Palette.inkFixed, selected: scope == .group(g.link.zone)) }
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
                if cards.isEmpty {
                    Spacer()
                    EmptyState(emoji: "🦗", title: "NOTHING TO REPORT", message: "Quiet \(period == .day ? "day" : period == .week ? "week" : "month"). Suspiciously quiet.")
                        .sticker(.white)
                    Spacer()
                } else {
                    HStack(spacing: 4) {
                        ForEach(cards.indices, id: \.self) { i in
                            Capsule().fill(i <= index ? Palette.inkFixed : Palette.inkFixed.opacity(0.25)).frame(height: 5)
                        }
                    }
                    TabView(selection: $index) {
                        ForEach(cards.indices, id: \.self) { i in
                            HighlightCardView(card: cards[i], compact: false)
                                .padding(.vertical, 10)
                                .tag(i)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    if cards.indices.contains(index) {
                        ShareCardButton(card: cards[index], period: period)
                    }
                }
            }
            .gutter()
            .padding(.vertical, 12)
        }
    }
}

struct HighlightCardView: View {
    var card: HighlightCard
    var compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 14) {
            Text(card.emoji).font(.system(size: compact ? 34 : 90))
            Text(card.title)
                .font(.heading(compact ? 12 : 20))
                .tracking(1)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            Text(card.headline)
                .font(.display(compact ? 24 : 54))
                .lineLimit(compact ? 1 : 2)
                .minimumScaleFactor(0.4)
            Text(card.detail)
                .font(.ui(compact ? 13 : 20, .bold))
                .lineLimit(2)
            if !compact { Spacer(minLength: 0) }
        }
        .foregroundStyle(card.color.ink)
        .frame(maxWidth: .infinity, maxHeight: compact ? nil : .infinity, alignment: .topLeading)
        .padding(compact ? 14 : 26)
        .sticker(card.color.color, radius: compact ? 22 : 34, shadow: compact ? 4 : 7)
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
