import SwiftUI

struct OnboardingFlow: View {
    @Environment(AppModel.self) private var model
    @State private var step = 0
    /// Neutral age screen: date of birth is asked, checked, and never stored.
    /// Starts near a typical birth year so nobody scrolls back decades from today.
    @State private var birthDate = Calendar.current.date(from: DateComponents(year: 2000, month: 1, day: 1)) ?? Date()
    @State private var pickedBirthDate = false
    @AppStorage("sf.ageBlocked") private var ageBlocked = false
    @State private var confirmUnderage = false
    @State private var handle = ""
    @State private var avatar = AvatarSpec.random()
    @State private var color = IdentityColor.random()
    @State private var demoPulse = 0

    private let colors: [Color] = [Palette.sun, Palette.blue, Palette.aqua, Palette.pink, Palette.lime, Palette.violet, Palette.tangerine]
    private static let stepCount = 7

    var body: some View {
        ZStack {
            colors[min(step, colors.count - 1)].ignoresSafeArea().animation(Motion.soft, value: step)
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    // Back (steps 2–7). The age step is the door, so it has nothing behind it.
                    Button {
                        Haptics.tick()
                        step = max(0, step - 1)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .black))
                            .foregroundStyle(Palette.inkFixed)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Color.white.opacity(0.55)))
                    }
                    .buttonStyle(PressableStyle())
                    .opacity(step > 0 ? 1 : 0)
                    .disabled(step == 0)
                    .accessibilityLabel("Back")
                    .accessibilityHidden(step == 0)
                    HStack(spacing: 6) {
                        ForEach(0..<Self.stepCount, id: \.self) { i in
                            Capsule().fill(i <= step ? Palette.inkFixed : Palette.inkFixed.opacity(0.2)).frame(height: 5)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Step \(step + 1) of \(Self.stepCount)")
                }
                .gutter()
                .padding(.top, 10)
                Group {
                    switch step {
                    case 0: welcome
                    case 1: signIn
                    case 2: identity
                    case 3: friends
                    case 4: taps
                    case 5: notifications
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

    /// Sign in with Apple / Google. Skippable: logging works without an account.
    private var signIn: some View {
        SignInView(inOnboarding: true) { next() }
    }

    // MARK: 3

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

    // MARK: 4

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
            Button("SKIP FOR NOW") { next() }
                .font(.heading(13))
                .foregroundStyle(Palette.inkFixed)
        }
        .gutter()
        .padding(.bottom, 20)
    }

    // MARK: 5

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
            Text("Either way, +1 counts the moment you tap. During a timer, tap the big poop: every tap pays 1 point, for as long as the timer runs. Spend points on collectible poops.")
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

    // MARK: 6

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
            Button("NOT NOW") { next() }
                .font(.heading(13))
                .foregroundStyle(Palette.inkFixed)
        }
        .gutter()
        .padding(.bottom, 20)
    }

    // MARK: 7

    private var location: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("📍").font(.system(size: 64)).padding(.top, 24)
                Text("EVERY POOP\nGETS A PIN").font(.display(30)).multilineTextAlignment(.center).foregroundStyle(Palette.inkFixed)
                Text("Your poops land on the map so friends can see where it happened. Location is read once when you log, never in the background. iOS asks the first time you poop.")
                    .font(.ui(15, .medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Palette.inkFixed.opacity(0.85))
                VStack(alignment: .leading, spacing: 12) {
                    tip("📍", "Wrong place name?", "Rename it from the poop in CALENDAR. The pin itself stays where you were.")
                    tip("⚙️", "Settings live behind your poop", "On the YOU tab, tap your 3D poop (top right) for notifications, location, privacy and your data.")
                    tip("🙂", "Your face on HOME", "It sits above POOP NOW and lights up when friends are pooping or something's waiting for you. Tap it.")
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .sticker(.white, radius: 20, shadow: 3)
                Button("START POOPING") { finish() }
                    .buttonStyle(.sticker(.white, ink: Palette.inkFixed, height: 62))
                    .padding(.top, 6)
            }
            .gutter()
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
    }

    private func tip(_ emoji: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(emoji).font(.system(size: 22))
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased()).font(.heading(12))
                Text(detail).font(.ui(13, .medium)).opacity(0.8)
            }
        }
        .foregroundStyle(Palette.inkFixed)
        .accessibilityElement(children: .combine)
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
                Text(model.availability.isAvailable ? "You can invite friends anytime from HOME → 👥." : "Sign in first (go back one step, or later in YOU → Settings) to invite friends. You can do this anytime from HOME → 👥.")
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
