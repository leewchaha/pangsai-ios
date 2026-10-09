import AuthenticationServices
import CryptoKit
import FirebaseAuth
import FirebaseCore
import Foundation
import Observation
import UIKit
import os
#if canImport(GoogleSignIn)
import GoogleSignIn
#endif

private let log = Logger(subsystem: "com.sakara.shittyfriends", category: "auth")

/// Sign-in state. The Firebase user id is the app's `UserID`: it never changes for an account, whichever
/// provider (Apple, Google) the person used, so a later Google Play version sees the same friends.
@MainActor
@Observable
final class AuthService: NSObject {
    enum State: Equatable {
        case unknown
        case signedOut
        case signedIn(uid: UserID, provider: String)
    }

    enum AuthError: LocalizedError {
        case notConfigured
        case cancelled
        case noToken
        case googleUnavailable

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "This build has no Firebase configuration."
            case .cancelled: return "Sign-in was cancelled."
            case .noToken: return "Sign-in didn't return a token. Try again."
            case .googleUnavailable: return "Google sign-in isn't set up in this build."
            }
        }
    }

    private(set) var state: State = .unknown
    @ObservationIgnored var onChange: ((State) -> Void)?
    @ObservationIgnored private var listener: AuthStateDidChangeListenerHandle?
    @ObservationIgnored private var currentNonce: String?
    @ObservationIgnored private var appleContinuation: CheckedContinuation<ASAuthorization, Error>?

    var uid: UserID? {
        if case .signedIn(let uid, _) = state { return uid }
        return nil
    }

    var isSignedIn: Bool { uid != nil }

    func start() {
        guard FirebaseConfig.isConfigured, listener == nil else {
            if !FirebaseConfig.isConfigured { set(.signedOut) }
            return
        }
        listener = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                guard let self else { return }
                if let user {
                    self.set(.signedIn(uid: user.uid, provider: user.providerData.first?.providerID ?? "firebase"))
                } else {
                    self.set(.signedOut)
                }
            }
        }
    }

    private func set(_ s: State) {
        guard s != state else { return }
        state = s
        onChange?(s)
    }

    // MARK: - Sign in with Apple

    func signInWithApple() async throws {
        guard FirebaseConfig.isConfigured else { throw AuthError.notConfigured }
        let nonce = Self.randomNonce()
        currentNonce = nonce
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = []
        request.nonce = Self.sha256(nonce)
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        let authorization: ASAuthorization = try await withCheckedThrowingContinuation { cont in
            appleContinuation = cont
            controller.performRequests()
        }
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken, let token = String(data: tokenData, encoding: .utf8) else {
            throw AuthError.noToken
        }
        let firebaseCredential = OAuthProvider.credential(withProviderID: "apple.com", idToken: token, rawNonce: nonce)
        _ = try await Auth.auth().signIn(with: firebaseCredential)
        log.info("signed in with Apple")
    }

    // MARK: - Google (optional: only when the GoogleSignIn package and GIDClientID are present)

    var isGoogleAvailable: Bool {
        #if canImport(GoogleSignIn)
        return FirebaseConfig.isConfigured && FirebaseApp.app()?.options.clientID != nil
        #else
        return false
        #endif
    }

    func signInWithGoogle() async throws {
        #if canImport(GoogleSignIn)
        guard FirebaseConfig.isConfigured, let clientID = FirebaseApp.app()?.options.clientID else { throw AuthError.googleUnavailable }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        guard let presenter = Self.topViewController() else { throw AuthError.cancelled }
        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
        guard let idToken = result.user.idToken?.tokenString else { throw AuthError.noToken }
        let credential = GoogleAuthProvider.credential(withIDToken: idToken, accessToken: result.user.accessToken.tokenString)
        _ = try await Auth.auth().signIn(with: credential)
        log.info("signed in with Google")
        #else
        throw AuthError.googleUnavailable
        #endif
    }

    /// Google's redirect back into the app.
    @discardableResult
    func handle(url: URL) -> Bool {
        #if canImport(GoogleSignIn)
        return GIDSignIn.sharedInstance.handle(url)
        #else
        return false
        #endif
    }

    // MARK: - Sign out / delete

    func signOut() {
        guard FirebaseConfig.isConfigured else { return }
        do {
            try Auth.auth().signOut()
            #if canImport(GoogleSignIn)
            GIDSignIn.sharedInstance.signOut()
            #endif
        } catch {
            log.error("sign out failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Helpers

    private static func randomNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length
        while remaining > 0 {
            var random: UInt8 = 0
            let status = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
            if status != errSecSuccess { random = UInt8.random(in: 0...255) }
            if random < charset.count {
                result.append(charset[Int(random)])
                remaining -= 1
            }
        }
        return result
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let window = scenes.flatMap({ $0.windows }).first(where: { $0.isKeyWindow }) ?? scenes.first?.windows.first else { return nil }
        var top = window.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

extension AuthService: ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        Task { @MainActor in
            appleContinuation?.resume(returning: authorization)
            appleContinuation = nil
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        Task { @MainActor in
            let code = (error as? ASAuthorizationError)?.code
            appleContinuation?.resume(throwing: code == .canceled ? AuthError.cancelled : error)
            appleContinuation = nil
        }
    }

    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.flatMap { $0.windows }.first(where: { $0.isKeyWindow }) ?? ASPresentationAnchor()
        }
    }
}
