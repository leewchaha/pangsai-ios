import Photos
import SwiftUI

struct PosterCallout: Hashable {
    var title: String
    var headline: String
    var detail: String
    var color: IdentityColor
}

struct HighlightConclusionPosterData: Hashable {
    var title: String
    var scopeTitle: String
    var isGroup: Bool
    /// "OCT 6 – 12" etc.
    var rangeLabel: String
    var total: String
    var summaryLine: String
    var callouts: [PosterCallout]
    var cosmetic: CosmeticID
    var shine: PinShineID
}

struct ProfilePosterData: Hashable {
    var handle: String
    var totalPoops: Int
    var streak: Int
    var places: Int
    var trophies: Int
    var cosmetic: CosmeticID
    var shine: PinShineID
    var identityLine: String
    var joinedYear: String
    var color: IdentityColor
    var avatar: AvatarSpec
    /// My friend-invite link, shown as a QR so people can add me straight from the poster.
    var inviteURL: String?
}

enum ConclusionPosterStyle: String, CaseIterable, Hashable {
    case boldMinimal, magazine, collage, cinematic, neonDark
    static func random() -> Self { allCases.randomElement() ?? .boldMinimal }
    /// SHUFFLE always changes the look.
    static func random(excluding current: Self) -> Self { allCases.filter { $0 != current }.randomElement() ?? .boldMinimal }
}

enum ProfilePosterStyle: String, CaseIterable, Hashable {
    case boldIdentity, cleanMinimal, collage, cinematic, illustration
    static func random() -> Self { allCases.randomElement() ?? .boldIdentity }
    /// SHUFFLE always changes the look.
    static func random(excluding current: Self) -> Self { allCases.filter { $0 != current }.randomElement() ?? .boldIdentity }
}

enum PosterBuilder {
    static func conclusionData(cards: [HighlightCard], period: HighlightPeriod, scopeTitle: String, isGroup: Bool, rangeLabel: String, store: Store) -> HighlightConclusionPosterData {
        let totalCard = cards.first(where: { $0.kind == .total }) ?? cards.first
        let total = totalCard?.headline ?? "0"
        let summary = totalCard?.detail ?? HighlightsEngine.totalCopy(total: Int(total) ?? cards.count, isGroup: isGroup)
        // The total is the poster's hero number; the rest become callouts.
        let callouts = cards.filter { $0.kind != .total }.map { PosterCallout(title: $0.title, headline: $0.headline, detail: $0.detail, color: $0.color) }
        return HighlightConclusionPosterData(
            title: period.title,
            scopeTitle: scopeTitle,
            isGroup: isGroup,
            rangeLabel: rangeLabel,
            total: total,
            summaryLine: summary,
            callouts: callouts,
            cosmetic: store.profile.equippedCosmetic,
            shine: store.profile.equippedPinShine
        )
    }

    static func profileData(store: Store, inviteURL: URL?) -> ProfilePosterData {
        let stats = store.stats()
        return ProfilePosterData(
            handle: store.profile.handle,
            totalPoops: stats.total,
            streak: stats.longestStreak,
            places: stats.uniquePlaces,
            trophies: store.my.achievements.count,
            cosmetic: store.profile.equippedCosmetic,
            shine: store.profile.equippedPinShine,
            identityLine: identityLine(stats: stats),
            joinedYear: String(Calendar.current.component(.year, from: store.profile.createdAt)),
            color: store.profile.color,
            avatar: store.profile.avatar,
            inviteURL: inviteURL?.absoluteString
        )
    }

    private static func identityLine(stats: PoopStats) -> String {
        if let hour = stats.commonWindowStartHour, hour < 6 { return "MIDNIGHT POOPER" }
        if stats.uniquePlaces >= 10 { return "PUBLIC TOILET EXPLORER" }
        if stats.partyCount >= 5 { return "PARTY REGULAR" }
        if stats.longestStreak >= 14 { return "CERTIFIED SERIAL SHITTER" }
        return "PROFESSIONALLY UNPROFESSIONAL"
    }
}

/// Posters are designed on ONE fixed canvas and scaled to fit, so the preview, the share image and
/// the saved image always have the identical layout (no clipping when the preview is small).
enum PosterCanvas {
    static let size = CGSize(width: 360, height: 640)
    /// 360 × 640 × 3 = 1080 × 1920 export.
    static let exportScale: CGFloat = 3
}

struct PosterHost<Content: View>: View {
    @Environment(AppModel.self) private var model
    var title: String
    var exportID: String
    var poop: CosmeticID
    var onShuffle: () -> Void
    let content: Content
    @State private var exportURL: URL?
    @State private var exporting = false

    init(title: String, exportID: String, poop: CosmeticID, onShuffle: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.title = title
        self.exportID = exportID
        self.poop = poop
        self.onShuffle = onShuffle
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { geo in
                let scale = geo.size.width / PosterCanvas.size.width
                content
                    .frame(width: PosterCanvas.size.width, height: PosterCanvas.size.height)
                    .environment(\.colorScheme, .light)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
            .aspectRatio(PosterCanvas.size.width / PosterCanvas.size.height, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.black.opacity(0.08), lineWidth: 1))
            .frame(maxWidth: .infinity)

            HStack(spacing: 8) {
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("SHARE", systemImage: "square.and.arrow.up")
                            .font(.heading(10))
                            .foregroundStyle(Palette.inkFixed)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.sun))
                    }
                } else {
                    Label("PREPARING…", systemImage: "hourglass")
                        .font(.heading(10))
                        .foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.card))
                }

                Button {
                    Task { await saveToPhotos() }
                } label: {
                    Label(exporting ? "SAVING…" : "SAVE IMAGE", systemImage: "arrow.down.to.line")
                        .font(.heading(10))
                        .foregroundStyle(Palette.ink)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.card))
                }
                .disabled(exportURL == nil || exporting)

                Button(action: onShuffle) {
                    Label("SHUFFLE", systemImage: "shuffle")
                        .font(.heading(10))
                        .foregroundStyle(Palette.ink)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.card))
                }
            }
        }
        .task(id: exportID) { await renderExport() }
        .task(id: poop) { RenderCache.shared.request(.poop(poop)) }
    }

    @MainActor private func renderExport() async {
        exportURL = nil
        exporting = true
        await warmPoopImage()
        let renderer = ImageRenderer(content:
            content
                .frame(width: PosterCanvas.size.width, height: PosterCanvas.size.height)
                .environment(\.colorScheme, .light)
        )
        renderer.scale = PosterCanvas.exportScale
        if let image = renderer.uiImage, let data = image.pngData() {
            // Never put user text (group names can contain "/") in the file name.
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("ShittyFriends-poster-\(UUID().uuidString).png")
            do {
                try data.write(to: url, options: .atomic)
                exportURL = url
            } catch {
                exportURL = nil
            }
        }
        exporting = false
    }

    private func warmPoopImage() async {
        let subject = RenderCache.Subject.poop(poop)
        RenderCache.shared.request(subject)
        for _ in 0..<60 {
            if RenderCache.shared.image(subject) != nil { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func saveToPhotos() async {
        guard let exportURL else { return }
        exporting = true
        do {
            try await PhotoLibrarySaver.saveImage(at: exportURL)
            model.info("SAVED", "Poster saved to Photos.")
        } catch {
            model.error("COULDN'T SAVE", error)
        }
        exporting = false
    }
}

enum PhotoLibrarySaver {
    enum SaveError: LocalizedError {
        case denied
        case failed
        var errorDescription: String? {
            switch self {
            case .denied: return "Photos access was denied."
            case .failed: return "Saving to Photos failed."
            }
        }
    }

    static func saveImage(at url: URL) async throws {
        let status = await withCheckedContinuation { (cont: CheckedContinuation<PHAuthorizationStatus, Never>) in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { cont.resume(returning: $0) }
        }
        guard status == .authorized || status == .limited else { throw SaveError.denied }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let req = PHAssetCreationRequest.forAsset()
                req.addResource(with: .photo, fileURL: url, options: nil)
            } completionHandler: { ok, err in
                if let err { cont.resume(throwing: err) }
                else if ok { cont.resume() }
                else { cont.resume(throwing: SaveError.failed) }
            }
        }
    }
}

// MARK: - Conclusion poster (designed on the fixed 360 × 640 canvas)

struct ConclusionPosterView: View {
    var data: HighlightConclusionPosterData
    var style: ConclusionPosterStyle

    private static let navy = Color(red: 0.13, green: 0.24, blue: 0.48)
    private static let note = Color(red: 1.0, green: 0.93, blue: 0.47)

    private var periodWord: String {
        if data.title.contains("TODAY") { return "DAY" }
        if data.title.contains("MONTH") { return "MONTH" }
        return "WEEK"
    }

    private var bigTitle: String { (data.isGroup ? "OUR " : "MY ") + periodWord + "\nIN SHIT" }

    var body: some View {
        ZStack {
            background
            switch style {
            case .boldMinimal: boldMinimal
            case .magazine: magazine
            case .collage: collage
            case .cinematic: cinematic
            case .neonDark: neonDark
            }
        }
        .frame(width: PosterCanvas.size.width, height: PosterCanvas.size.height)
        .clipped()
    }

    @ViewBuilder private var background: some View {
        switch style {
        case .boldMinimal:
            LinearGradient(colors: [Color(red: 0.14, green: 0.19, blue: 0.05), Palette.inkFixed], startPoint: .top, endPoint: .bottom)
        case .magazine:
            LinearGradient(colors: [Color(red: 0.64, green: 0.81, blue: 1), .white], startPoint: .top, endPoint: .bottom)
        case .collage:
            LinearGradient(colors: [Color(red: 0.08, green: 0.08, blue: 0.10), Color(red: 0.17, green: 0.16, blue: 0.20)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .cinematic:
            ZStack {
                LinearGradient(colors: [Color(red: 0.96, green: 0.76, blue: 0.68), Color(red: 0.40, green: 0.27, blue: 0.30)], startPoint: .top, endPoint: .bottom)
                LinearGradient(colors: [.clear, Color.black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
            }
        case .neonDark:
            LinearGradient(colors: [.black, Color(red: 0.10, green: 0.03, blue: 0.18)], startPoint: .top, endPoint: .bottom)
        }
    }

    // MARK: Shared pieces (every text that can hold a handle shrinks instead of clipping)

    private func brand(_ ink: Color) -> some View {
        HStack(spacing: 8) {
            Text("SHITTYFRIENDS").font(.heading(9))
            Spacer(minLength: 8)
            Text(data.scopeTitle + " · " + data.rangeLabel)
                .font(.heading(9))
                .lineLimit(1)
                .minimumScaleFactor(0.55)
        }
        .foregroundStyle(ink)
    }

    private func hero(_ size: CGFloat) -> some View {
        ZStack {
            PinShineEffect(id: data.shine, animated: false)
                .frame(width: size * 1.25, height: size * 1.25)
            Object3DImage(subject: .poop(data.cosmetic), size: size)
        }
        .frame(width: size * 1.25, height: size * 1.25)
    }

    private func calloutRows(_ items: [PosterCallout], ink: Color, sub: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, c in
                HStack(alignment: .center, spacing: 10) {
                    Circle().fill(c.color.color).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.title)
                            .font(.heading(9))
                            .foregroundStyle(sub)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(c.headline)
                            .font(.system(size: 16, weight: .black, design: .rounded))
                            .foregroundStyle(ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.45)
                    }
                    Spacer(minLength: 6)
                    Text(c.detail)
                        .font(.ui(10, .semibold))
                        .foregroundStyle(sub)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: 112, alignment: .trailing)
                }
            }
        }
    }

    private func noteCard(_ title: String, _ subtitle: String, small: Bool = false, tilt: Double = 2) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: small ? 16 : 30, weight: .black, design: .rounded))
                .lineLimit(small ? 3 : 2)
                .minimumScaleFactor(0.45)
            Text(subtitle)
                .font(.heading(9))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .foregroundStyle(Palette.inkFixed)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(ConclusionPosterView.note))
        .rotationEffect(.degrees(tilt))
    }

    private func statBadge(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 26, weight: .black, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.4)
            Text(label)
                .font(.heading(9))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Styles

    private var boldMinimal: some View {
        VStack(alignment: .leading, spacing: 12) {
            brand(.white.opacity(0.85))
            Text(bigTitle)
                .font(.system(size: 46, weight: .black, design: .rounded))
                .foregroundStyle(Palette.lime)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
            HStack(alignment: .center, spacing: 10) {
                hero(110)
                VStack(alignment: .leading, spacing: 4) {
                    Text(data.total)
                        .font(.system(size: 64, weight: .black, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.4)
                    Text("TOTAL POOPS").font(.heading(10))
                    Text(data.summaryLine.uppercased())
                        .font(.ui(12, .bold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                }
                .foregroundStyle(.white)
            }
            Spacer(minLength: 0)
            calloutRows(Array(data.callouts.prefix(4)), ink: .white, sub: .white.opacity(0.7))
            Text("A \(periodWord) WELL SPENT.").font(.heading(10)).foregroundStyle(Palette.lime)
        }
        .padding(24)
    }

    private var magazine: some View {
        VStack(alignment: .leading, spacing: 10) {
            brand(ConclusionPosterView.navy.opacity(0.75))
            Text("SHITTY")
                .font(.system(size: 76, weight: .black, design: .serif))
                .foregroundStyle(ConclusionPosterView.navy)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text("THE \(periodWord) ISSUE")
                .font(.heading(11))
                .foregroundStyle(ConclusionPosterView.navy.opacity(0.75))
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(data.total)
                        .font(.system(size: 70, weight: .black, design: .rounded))
                        .foregroundStyle(Palette.tomato)
                        .lineLimit(1)
                        .minimumScaleFactor(0.4)
                    Text("TOTAL POOPS").font(.heading(10)).foregroundStyle(Palette.inkFixed)
                }
                Spacer(minLength: 8)
                hero(120)
            }
            Text(data.summaryLine.uppercased())
                .font(.system(size: 18, weight: .heavy, design: .rounded))
                .foregroundStyle(Palette.inkFixed)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
            Spacer(minLength: 0)
            calloutRows(Array(data.callouts.prefix(4)), ink: Palette.inkFixed, sub: Palette.inkFixed.opacity(0.55))
        }
        .padding(24)
    }

    private var collage: some View {
        VStack(alignment: .leading, spacing: 10) {
            brand(.white.opacity(0.8))
            Text("ANOTHER \(periodWord) OF")
                .font(.system(size: 24, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text("SHIT")
                .font(.system(size: 84, weight: .black, design: .rounded))
                .foregroundStyle(Palette.tomato)
                .lineLimit(1)
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 12) {
                    noteCard(data.total, "TOTAL POOPS", tilt: 3)
                    if let c = data.callouts.first {
                        noteCard(c.headline, c.title, small: true, tilt: -2)
                    }
                }
                .frame(width: 150)
                VStack(spacing: 8) {
                    hero(104)
                    noteCard(data.summaryLine, "FINAL WORD", small: true, tilt: -2)
                }
            }
            Spacer(minLength: 0)
            calloutRows(Array(data.callouts.dropFirst().prefix(3)), ink: .white, sub: .white.opacity(0.7))
        }
        .padding(24)
    }

    private var cinematic: some View {
        VStack(alignment: .leading, spacing: 10) {
            brand(.white.opacity(0.8))
            Spacer(minLength: 0)
            hero(140)
                .frame(maxWidth: .infinity)
            Text("A \(periodWord.capitalized)\nWell Spent.")
                .font(.system(size: 40, weight: .light, design: .serif))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
            HStack(spacing: 16) {
                statBadge(data.total, "POOPS")
                statBadge(data.callouts.first?.headline ?? "—", data.callouts.first?.title ?? "HIGHLIGHT")
            }
            calloutRows(Array(data.callouts.dropFirst().prefix(2)), ink: .white, sub: .white.opacity(0.75))
        }
        .padding(24)
    }

    private var neonDark: some View {
        VStack(alignment: .leading, spacing: 10) {
            brand(.white.opacity(0.8))
            Spacer(minLength: 0)
            Text(data.total)
                .font(.system(size: 110, weight: .black, design: .rounded))
                .foregroundStyle(.yellow)
                .shadow(color: .pink.opacity(0.65), radius: 14)
                .lineLimit(1)
                .minimumScaleFactor(0.35)
            Text("TOTAL POOPS")
                .font(.heading(12))
                .foregroundStyle(.white)
            hero(130)
                .frame(maxWidth: .infinity)
            calloutRows(Array(data.callouts.prefix(3)), ink: .pink, sub: .white.opacity(0.75))
            Text("ANOTHER SHITTY \(periodWord).")
                .font(.heading(11))
                .foregroundStyle(.orange)
        }
        .padding(24)
    }
}

// MARK: - Profile poster (fixed 360 × 640 canvas, with an add-me QR)

struct ProfilePosterView: View {
    var data: ProfilePosterData
    var style: ProfilePosterStyle

    private struct Theme {
        var background: [Color]
        var ink: Color
        var sub: Color
        var accent: Color
        var card: Color
        var titleDesign: Font.Design
        var centered: Bool
    }

    private var theme: Theme {
        switch style {
        case .boldIdentity:
            return Theme(background: [Palette.lime, Palette.lime], ink: Palette.inkFixed, sub: Palette.inkFixed.opacity(0.6), accent: Palette.inkFixed, card: .white.opacity(0.55), titleDesign: .rounded, centered: false)
        case .cleanMinimal:
            return Theme(background: [Color(red: 0.98, green: 0.97, blue: 0.95), Color(red: 0.94, green: 0.93, blue: 0.90)], ink: Palette.inkFixed, sub: Palette.inkFixed.opacity(0.5), accent: Palette.tomato, card: .white, titleDesign: .rounded, centered: true)
        case .collage:
            return Theme(background: [Color(red: 0.10, green: 0.10, blue: 0.12), Color(red: 0.17, green: 0.15, blue: 0.20)], ink: .white, sub: .white.opacity(0.65), accent: Color(red: 1.0, green: 0.93, blue: 0.47), card: .white.opacity(0.1), titleDesign: .rounded, centered: false)
        case .cinematic:
            return Theme(background: [Color(red: 0.07, green: 0.06, blue: 0.08), Color(red: 0.32, green: 0.19, blue: 0.08)], ink: .white, sub: .white.opacity(0.65), accent: Color(red: 1.0, green: 0.78, blue: 0.4), card: .white.opacity(0.1), titleDesign: .serif, centered: true)
        case .illustration:
            return Theme(background: [Color(red: 1.0, green: 0.97, blue: 0.85), Color(red: 1.0, green: 0.90, blue: 0.80)], ink: Palette.inkFixed, sub: Palette.inkFixed.opacity(0.55), accent: Palette.pink, card: .white.opacity(0.8), titleDesign: .rounded, centered: false)
        }
    }

    var body: some View {
        let t = theme
        ZStack {
            LinearGradient(colors: t.background, startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(alignment: t.centered ? .center : .leading, spacing: t.centered ? 8 : 10) {
                HStack {
                    Text("SHITTYFRIENDS").font(.heading(9))
                    Spacer()
                    Text("SINCE \(data.joinedYear)").font(.heading(9))
                }
                .foregroundStyle(t.sub)

                identity(t)

                Text(data.identityLine)
                    .font(.system(size: 17, weight: .heavy, design: t.titleDesign))
                    .foregroundStyle(t.accent)
                    .multilineTextAlignment(t.centered ? .center : .leading)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)

                // Centred styles stack avatar over handle, so their hero is a little smaller to keep
                // everything inside the 640 pt canvas.
                let heroSize: CGFloat = t.centered ? 140 : 168
                ZStack {
                    PinShineEffect(id: data.shine, animated: false).frame(width: heroSize, height: heroSize)
                    Object3DImage(subject: .poop(data.cosmetic), size: heroSize * 0.8)
                }
                .frame(maxWidth: .infinity)
                .frame(height: heroSize)

                metrics(t)
                Spacer(minLength: 0)
                addMe(t)
            }
            .padding(22)
        }
        .frame(width: PosterCanvas.size.width, height: PosterCanvas.size.height)
        .clipped()
    }

    @ViewBuilder private func identity(_ t: Theme) -> some View {
        let handle = Text("@\(data.handle)")
            .font(.system(size: 44, weight: .black, design: t.titleDesign))
            .foregroundStyle(t.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.3)
        if t.centered {
            VStack(spacing: 6) {
                AvatarView(spec: data.avatar, color: data.color, size: 58)
                handle
            }
        } else {
            HStack(spacing: 10) {
                AvatarView(spec: data.avatar, color: data.color, size: 52)
                handle
            }
        }
    }

    private func metrics(_ t: Theme) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                metric("\(data.totalPoops)", "TOTAL POOPS", t)
                metric("\(data.streak)", "BEST STREAK", t)
            }
            HStack(spacing: 8) {
                metric("\(data.places)", "PLACES", t)
                metric("\(data.trophies)", "TROPHIES", t)
            }
        }
    }

    private func metric(_ value: String, _ label: String, _ t: Theme) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 24, weight: .black, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.4)
            Text(label)
                .font(.heading(9))
                .foregroundStyle(t.sub)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(t.ink)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(t.card))
    }

    /// Scan-to-add block: the QR is my friend-invite link (it still asks me to accept).
    private func addMe(_ t: Theme) -> some View {
        HStack(spacing: 12) {
            Group {
                if let link = data.inviteURL, let img = QRCodeView.image(for: link) {
                    Image(uiImage: img)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "qrcode")
                        .font(.system(size: 40, weight: .regular))
                        .foregroundStyle(Palette.inkFixed.opacity(0.25))
                }
            }
            .frame(width: 78, height: 78)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white))

            VStack(alignment: .leading, spacing: 3) {
                Text("SCAN TO ADD ME").font(.heading(11)).foregroundStyle(t.ink)
                Text("@\(data.handle)")
                    .font(.heading(14))
                    .foregroundStyle(t.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.45)
                Text(data.inviteURL == nil ? "Invite link needs iCloud." : "Opens ShittyFriends. Invite links expire within a week.")
                    .font(.ui(10, .semibold))
                    .foregroundStyle(t.sub)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Text("\(data.cosmetic.displayName) · \(data.shine.displayName)")
                    .font(.ui(10, .bold))
                    .foregroundStyle(t.sub)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(t.card))
    }
}

struct ProfilePosterSheetView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var style: ProfilePosterStyle = .random()
    @State private var inviteURL: URL?

    var body: some View {
        let data = PosterBuilder.profileData(store: model.store, inviteURL: inviteURL)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("SHARE PROFILE").font(.heading(14))
                            Text("Friends scan the QR to add you. Shuffle for another look.")
                                .font(.ui(12, .medium))
                                .foregroundStyle(Palette.muted)
                        }
                        Spacer()
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 15, weight: .black))
                                .foregroundStyle(Palette.inkFixed)
                                .frame(width: 38, height: 38)
                                .background(Circle().fill(.white))
                        }
                        .accessibilityLabel("Close")
                    }
                    PosterHost(title: "PROFILE POSTER", exportID: "profile-poster-\(style.rawValue)-\(data.handle)-\(inviteURL == nil ? "noqr" : "qr")", poop: data.cosmetic, onShuffle: { style = .random(excluding: style) }) {
                        ProfilePosterView(data: data, style: style)
                    }
                }
                .gutter()
                .padding(.vertical, 14)
            }
            .background(Palette.paper.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .task {
                // Needs iCloud; without it the poster simply shows a placeholder instead of a QR.
                inviteURL = try? await model.friendInviteURL()
            }
        }
    }
}
