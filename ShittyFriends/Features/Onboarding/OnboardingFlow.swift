import SwiftUI

struct OnboardingFlow: View {
    @Environment(AppModel.self) private var model
    @State private var step = 0
    /// Neutral age screen: date of birth is asked, checked, and never stored.
    @State private var birthDate = Date()
    @State private var pickedBirthDate = false
    @AppStorage("sf.ageBlocked") private var ageBlocked = false
    @State private var confirmUnderage = false
    @State private var handle = ""
    @State private var avatar = AvatarSpec.random()
    @State private var color = IdentityColor.random()
    @State private var demoPulse = 0

    private let colors: [Color] = [Palette.sun, Palette.aqua, Palette.pink, Palette.lime, Palette.violet, Palette.tangerine]

    var body: some View {
        ZStack {
            colors[min(step, colors.count - 1)].ignoresSafeArea().animation(Motion.soft, value: step)
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    ForEach(0..<6, id: \.self) { i in
                        Capsule().fill(i <= step ? Palette.inkFixed : Palette.inkFixed.opacity(0.2)).frame(height: 5)
                    }
                }
                .gutter()
                .padding(.top, 10)
                Group {
                    switch step {
                    case 0: welcome
                    case 1: identity
                    case 2: friends
                    case 3: taps
                    case 4: notifications
                    default: location
                    }
                }
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
                .id(step)
            }
        }
        .animation(Motion.soft, value: step)
    }

    private func next() {
        Haptics.tick()
        step += 1
    }

    private func finish() {
        model.store.completeOnboarding(handle: handle, avatar: avatar, color: color)
        Haptics.play(.success)
    }

    // MARK: 1

    private var welcome: some View {
        VStack(spacing: 18) {
            Spacer()
            PoopStageView(cosmetic: .glossy, pulse: demoPulse)
                .frame(height: 240)
                .onTapGesture { demoPulse += 1; Haptics.play(.tapLight) }
            Text("SHITTY\nFRIENDS")
                .font(.display(52))
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.inkFixed)
            Text(Copy.tagline)
                .font(.heading(16))
                .foregroundStyle(Palette.inkFixed.opacity(0.8))
            Spacer()
            if ageBlocked {
                Text("ShittyFriends is for people 13 and older. Come back when you're older.")
                    .font(.heading(15))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Palette.inkFixed)
                    .padding(14)
                    .sticker(.white, radius: 18, shadow: 3)
            } else {
                VStack(spacing: 6) {
                    Text("WHEN WERE YOU BORN?").font(.heading(13)).foregroundStyle(Palette.inkFixed)
                    DatePicker("Date of birth", selection: Binding(get: { birthDate }, set: { birthDate = $0; pickedBirthDate = true }), in: ...Date(), displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .labelsHidden()
                    Text("Only used to check your age. Not saved.").font(.ui(12, .medium)).foregroundStyle(Palette.inkFixed.opacity(0.7))
                }
                Button("LET'S GO") {
                    let age = Calendar.current.dateComponents([.year], from: birthDate, to: Date()).year ?? 0
                    if age >= 13 {
                        model.store.confirmAge()
                        next()
                    } else {
                        // Double-check first: a slip on the date wheel shouldn't lock anyone out.
                        confirmUnderage = true
                    }
                }
                .buttonStyle(.sticker(.white, ink: Palette.inkFixed, height: 62))
                .disabled(!pickedBirthDate)
                .opacity(pickedBirthDate ? 1 : 0.5)
                .alert("Is that right?", isPresented: $confirmUnderage) {
                    Button("Change date", role: .cancel) {}
                    Button("Yes, that's right") {
                        ageBlocked = true
                        Haptics.play(.warning)
                    }
                } message: {
                    Text("You picked \(birthDate.formatted(date: .long, time: .omitted)).")
                }
            }
        }
        .gutter()
        .padding(.bottom, 20)
    }

    // MARK: 2

    private var identity: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("WHO ARE YOU?").font(.display(30)).foregroundStyle(Palette.inkFixed).padding(.top, 20)
                Text("A handle and a face. No real name needed.").font(.ui(15, .medium)).foregroundStyle(Palette.inkFixed.opacity(0.8))
                ProfileEditor(handle: $handle, avatar: $avatar, color: $color)
                    .padding(14)
                    .sticker(Palette.paper, radius: 28)
                Button("NEXT") {
                    model.store.saveProfileDraft(handle: handle, avatar: avatar, color: color)
                    next()
                }
                .buttonStyle(.sticker(.white, ink: Palette.inkFixed, height: 62))
                .disabled(HandleRules.validate(handle) != nil)
                .opacity(HandleRules.validate(handle) == nil ? 1 : 0.5)
            }
            .gutter()
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: 3

    private var friends: some View {
        VStack(spacing: 18) {
            Spacer()
            Text("ADD YOUR\nSHITTY FRIENDS").font(.display(32)).multilineTextAlignment(.center).foregroundStyle(Palette.inkFixed)
            Text("No search, no directory. Friends join with your link or QR. Both of you confirm, then you see each other's full history.")
                .font(.ui(15, .medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.inkFixed.opacity(0.85))
            OnboardingInviteBlock()
            Spacer()
            Button("NEXT") { next() }
                .buttonStyle(.sticker(.white, ink: Palette.inkFixed, height: 62))
            Button("Skip for now") { next() }
                .font(.heading(13))
                .foregroundStyle(Palette.inkFixed)
        }
        .gutter()
        .padding(.bottom, 20)
    }

    // MARK: 4

    private var taps: some View {
        VStack(spacing: 22) {
            Spacer()
            PoopStageView(cosmetic: .classic, pulse: demoPulse)
                .frame(height: 200)
            VStack(spacing: 14) {
                Text("ONE TAP = TIMER")
                    .font(.display(28))
                Text("DOUBLE TAP = INSTANT LOG")
                    .font(.display(22))
            }
            .foregroundStyle(Palette.inkFixed)
            Text("Either way, +1 counts the moment you tap. Tap the poop during a timer to earn points for collectible poops.")
                .font(.ui(15, .medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.inkFixed.opacity(0.85))
            PoopingButton { _ in demoPulse += 1 }
            Text("(practice — this one doesn't count)").font(.ui(12, .medium)).foregroundStyle(Palette.inkFixed.opacity(0.7))
            Spacer()
            Button("GOT IT") { next() }
                .buttonStyle(.sticker(.white, ink: Palette.inkFixed, height: 62))
        }
        .gutter()
        .padding(.bottom, 20)
    }

    // MARK: 5

    private var notifications: some View {
        VStack(spacing: 18) {
            Spacer()
            Text("🔔").font(.system(size: 80))
            Text("KNOW WHEN\nFRIENDS POOP").font(.display(30)).multilineTextAlignment(.center).foregroundStyle(Palette.inkFixed)
            Text("“💩 @sam is pooping.” Poop With Me invites. Party reminders. You can mute any friend, any group, or set quiet hours later.")
                .font(.ui(15, .medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.inkFixed.opacity(0.85))
            Spacer()
            Button("TURN ON NOTIFICATIONS") {
                Task {
                    await model.notifications.requestAuthorization()
                    next()
                }
            }
            .buttonStyle(.sticker(.white, ink: Palette.inkFixed, height: 62))
            Button("Not now") { next() }
                .font(.heading(13))
                .foregroundStyle(Palette.inkFixed)
        }
        .gutter()
        .padding(.bottom, 20)
    }

    // MARK: 6

    private var location: some View {
        VStack(spacing: 18) {
            Spacer()
            Text("📍").font(.system(size: 80))
            Text("ADD WHERE\nYOU POOP?").font(.display(30)).multilineTextAlignment(.center).foregroundStyle(Palette.inkFixed)
            Text("ShittyFriends can attach your location to a poop so friends can see where it happened. Optional, per poop, never in the background. We'll ask when you first tap 📍.")
                .font(.ui(15, .medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.inkFixed.opacity(0.85))
            Spacer()
            Button("START POOPING") { finish() }
                .buttonStyle(.sticker(.white, ink: Palette.inkFixed, height: 62))
        }
        .gutter()
        .padding(.bottom, 20)
    }
}

/// QR + share link during onboarding (only if iCloud is ready).
struct OnboardingInviteBlock: View {
    @Environment(AppModel.self) private var model
    @State private var url: URL?
    @State private var failed = false

    var body: some View {
        Group {
            if let url {
                VStack(spacing: 12) {
                    QRCodeView(text: url.absoluteString, size: 150)
                    ShareLink(item: url, message: Text(model.friendInviteText(url))) {
                        Label("SHARE INVITE", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.sticker(Palette.sun))
                }
            } else if failed || !model.availability.isAvailable {
                Text(model.availability.message ?? "You can invite friends anytime from TODAY → 👥.")
                    .font(.ui(14, .semibold))
                    .foregroundStyle(Palette.inkFixed)
                    .multilineTextAlignment(.center)
                    .padding(14)
                    .sticker(.white, radius: 18, shadow: 3)
            } else {
                ProgressView().tint(Palette.inkFixed).frame(height: 150)
            }
        }
        .task(id: model.availability) {
            // Re-runs when the iCloud check finishes, so the QR appears without leaving the step.
            guard model.availability.isAvailable, url == nil else { return }
            failed = false
            do { url = try await model.friendInviteURL() } catch { failed = true }
        }
    }
}
