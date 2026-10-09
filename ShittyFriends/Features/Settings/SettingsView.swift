import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var exportURL: URL?
    @State private var importing = false
    @State private var confirmDelete = false
    @State private var confirmSignOut = false
    @State private var notificationsAllowed = true
    @State private var locationDeniedAlert = false
    @Environment(\.scenePhase) private var scenePhase
    /// Bumped when the app returns to the foreground so the iOS-permission row re-reads its state
    /// (LocationService isn't observable; the user may have just changed it in iOS Settings).
    @State private var permissionRefresh = 0
    @AppStorage("sf.map.showProfileBadges") private var showProfileBadges = true

    private var store: Store { model.store }

    private func binding(_ key: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(get: { store.settings[keyPath: key] }, set: { v in store.updateSettings { $0[keyPath: key] = v } })
    }

    private func minutesBinding(_ key: WritableKeyPath<AppSettings, Int>) -> Binding<Date> {
        Binding(get: {
            let m = store.settings[keyPath: key]
            return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
        }, set: { d in
            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
            store.updateSettings { $0[keyPath: key] = (c.hour ?? 0) * 60 + (c.minute ?? 0) }
        })
    }

    var body: some View {
        Form {
            Section {
                if !notificationsAllowed {
                    Button("Turn on notifications") {
                        Task {
                            notificationsAllowed = await model.notifications.requestAuthorization()
                            if !notificationsAllowed, let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url, options: [:], completionHandler: nil) }
                        }
                    }
                }
                Toggle("Friend poops", isOn: binding(\.notifyFriendPoops))
                Toggle("Poop With Me", isOn: binding(\.notifyPWM))
                Toggle("Poop Parties", isOn: binding(\.notifyParties))
                Toggle("Achievements", isOn: binding(\.notifyAchievements))
                Toggle("Daily summary", isOn: binding(\.dailySummary))
                Toggle("Weekly Shit Report", isOn: binding(\.weeklyReport))
                Toggle("Monthly highlights", isOn: binding(\.monthlyHighlights))
            } header: {
                Text("NOTIFICATIONS")
            } footer: {
                Text("Per-friend and per-group levels live on each friend's and group's page.")
            }

            Section {
                Toggle("Quiet hours", isOn: binding(\.quietHoursEnabled))
                if store.settings.quietHoursEnabled {
                    DatePicker("From", selection: minutesBinding(\.quietStartMinutes), displayedComponents: .hourAndMinute)
                    DatePicker("To", selection: minutesBinding(\.quietEndMinutes), displayedComponents: .hourAndMinute)
                }
                Toggle("Private lock screen", isOn: binding(\.lockScreenPrivate))
            } footer: {
                Text("Quiet hours deliver alerts silently. Private lock screen shows “@lee checked in” instead of “💩 @lee is pooping”.")
            }

            Section {
                // Every poop is pinned; this row only reports (and fixes) the iOS permission.
                HStack {
                    Text("Location")
                    Spacer()
                    let _ = permissionRefresh
                    Text(model.location.isAuthorized ? "Allowed" : (model.location.isDenied ? "Off in iOS Settings" : "Asks on your next poop"))
                        .foregroundStyle(.secondary)
                }
                if model.location.isDenied {
                    Button("Turn location back on") { locationDeniedAlert = true }
                }
                Toggle("“Still pooping?” reminder", isOn: binding(\.longSessionReminder))
            } header: {
                Text("POOPING")
            } footer: {
                Text("Every poop gets a pin on the map. Location is only read when a poop is logged, never in the background. Friends see your pins; groups only see them if you turn on “Include locations” for that group.")
            }

            Section {
                Toggle("Show profile badges on poop pins", isOn: $showProfileBadges)
            } header: {
                Text("MAP")
            } footer: {
                Text("Shows a small avatar on the newest person's poop pin. Turn off for poop-only pins. No photo uploads are required.")
            }

            if !store.settings.blockedUserIDs.isEmpty {
                Section("BLOCKED") {
                    ForEach(store.settings.blockedUserIDs, id: \.self) { uid in
                        HStack {
                            Text(store.blockedLabel(uid))
                            Spacer()
                            Button("Unblock") { store.unblock(uid) }
                        }
                    }
                }
            }

            Section {
                HStack {
                    Text("Account")
                    Spacer()
                    Text(accountStatus)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                if model.auth.isSignedIn {
                    Button("Sign out") { confirmSignOut = true }
                } else if model.availability != .notConfigured {
                    Button("Sign in") { model.sheet = .signIn }
                }
            } header: {
                Text("ACCOUNT")
            } footer: {
                Text(model.auth.isSignedIn
                     ? "Signing out pauses sync, friends and alerts; your history stays on this phone and in your account. A different account signing in clears this phone first."
                     : "Friends, groups and alerts need an account (Sign in with Apple\(model.auth.isGoogleAvailable ? " or Google" : "")). Logging works without one.")
            }

            Section {
                Button("Export my data") {
                    do { exportURL = try model.makeExport() } catch { model.error("Export failed", error) }
                }
                if let url = exportURL {
                    ShareLink(item: url) { Label("Share export (.zip)", systemImage: "square.and.arrow.up") }
                }
                Button("Import history from an export") { importing = true }
            } header: {
                Text("YOUR DATA")
            } footer: {
                Text("Your data lives on this device and, when you're signed in, in your ShittyFriends account (Firebase). Friends see your history, groups see what you share with them, nobody else. Import takes the export .zip as-is (or the poop-history.json inside it); imported poops never bring points and stay out of leaderboards.")
            }

            Section {
                Button(model.auth.isSignedIn ? "Delete my account and all my data" : "Delete all my data", role: .destructive) { confirmDelete = true }
            } footer: {
                Text(model.auth.isSignedIn
                     ? "Deletes your history, friendships, memberships, groups you own and your sign-in from the server, and everything on this device. Your other devices sign out."
                     : "Deletes everything on this device.")
            }

            Section("ABOUT") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                LabeledContent("Build", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1")
                Text(Copy.tagline).foregroundStyle(.secondary)
            }
        }
        // The app's global tint is adaptive ink (nearly white in dark mode),
        // which made enabled UISwitch tracks indistinguishable from their thumbs.
        // Keep a saturated, legible track color independent of appearance.
        .tint(Palette.violet)
        .clearsTabBar()
        .navigationTitle("SETTINGS")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.notifications.refreshAuthorization()
            let s = model.notifications.authorization
            notificationsAllowed = s == .authorized || s == .provisional || s == .ephemeral
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.zip, .json]) { result in
            switch result {
            case .success(let url):
                do {
                    let n = try model.importHistory(from: url)
                    model.info("IMPORTED", "\(n) new poop\(n == 1 ? "" : "s") added.")
                } catch {
                    model.error("Import failed", error)
                }
            case .failure(let error):
                model.error("Import failed", error)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { permissionRefresh += 1 }
        }
        .alert("Location is off in iOS Settings", isPresented: $locationDeniedAlert) {
            Button("Open iOS Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("Poops can't get map pins until location is allowed for ShittyFriends in iOS Settings.")
        }
        .confirmationDialog("Delete everything?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete all my data", role: .destructive) {
                Task { await model.deleteAllMyData() }
            }
        } message: {
            Text("This can't be undone. Export first if you want a copy.")
        }
        .confirmationDialog("Sign out?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) {
                Task { await model.signOut() }
            }
        } message: {
            Text("Unsent changes are sent first. Your history stays here; sync, friends and alerts pause until you sign in again.")
        }
    }

    private var accountStatus: String {
        switch model.auth.state {
        case .signedIn(_, let provider): return provider == "apple.com" ? "Apple" : provider == "google.com" ? "Google" : "Signed in"
        case .signedOut: return model.availability == .notConfigured ? "Not configured" : "Not signed in"
        case .unknown: return "Checking…"
        }
    }
}
