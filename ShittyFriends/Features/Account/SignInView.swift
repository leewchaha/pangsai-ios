import AuthenticationServices
import SwiftUI

/// Sign in with Apple (and Google, when the build is configured for it). One account = one identity
/// across devices and, later, across platforms. Used as an onboarding step and from Settings.
struct SignInView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Onboarding: fixed bright background, no close button, optional "NOT NOW".
    var inOnboarding: Bool
    var onDone: (() -> Void)? = nil
    @State private var working = false

    private var ink: Color { inOnboarding ? Palette.inkFixed : Palette.ink }

    var body: some View {
        VStack(spacing: 18) {
            if !inOnboarding {
                HStack {
                    Spacer()
                    Button("Close") { dismiss() }
                        .font(.heading(14))
                        .foregroundStyle(Palette.ink)
                }
            }
            Spacer()
            Text("🔑").font(.system(size: 64))
            Text(inOnboarding ? "ONE ACCOUNT,\nEVERY DEVICE" : "SIGN IN")
                .font(.display(30))
                .multilineTextAlignment(.center)
                .foregroundStyle(ink)
            Text("Friends, groups and alerts need an account. Your history still lives on this phone first; the account keeps it safe and in sync. No real name, no email shown to anyone.")
                .font(.ui(15, .medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(ink.opacity(0.85))
            if !model.availability.isAvailable, let msg = model.availability.message, model.availability != .noAccount {
                InfoBanner(text: msg, fill: Palette.paper2)
            }
            Spacer()
            if model.auth.isSignedIn {
                Text("SIGNED IN").font(.heading(14)).foregroundStyle(ink)
                Button("CONTINUE") { finish() }
                    .buttonStyle(.sticker(.white, ink: Palette.inkFixed, height: 62))
            } else {
                SignInWithAppleButton(.signIn) { _ in } onCompletion: { _ in }
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay {
                        // The system button draws the branding; the tap runs our async flow.
                        Color.clear.contentShape(Rectangle()).onTapGesture { signIn(apple: true) }
                    }
                    .disabled(working)
                    .accessibilityLabel("Sign in with Apple")
                if model.auth.isGoogleAvailable {
                    Button {
                        signIn(apple: false)
                    } label: {
                        Label("CONTINUE WITH GOOGLE", systemImage: "g.circle.fill")
                    }
                    .buttonStyle(.sticker(.white, ink: Palette.inkFixed, height: 56))
                    .disabled(working)
                }
                if inOnboarding {
                    Button("NOT NOW") { finish() }
                        .font(.heading(13))
                        .foregroundStyle(ink)
                        .disabled(working)
                    Text("You can sign in later from YOU → Settings. Until then: logging only, no friends.")
                        .font(.ui(12, .medium))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(ink.opacity(0.7))
                }
            }
            if working {
                ProgressView().tint(ink)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { if !inOnboarding { Palette.paper.ignoresSafeArea() } }
    }

    private func finish() {
        if let onDone { onDone() } else { dismiss() }
    }

    private func signIn(apple: Bool) {
        guard !working else { return }
        working = true
        Task {
            defer { working = false }
            do {
                if apple { try await model.auth.signInWithApple() } else { try await model.auth.signInWithGoogle() }
                Haptics.play(.success)
                finish()
            } catch AuthService.AuthError.cancelled {
                // Nothing to say.
            } catch {
                model.error("Couldn't sign in", error)
            }
        }
    }
}
