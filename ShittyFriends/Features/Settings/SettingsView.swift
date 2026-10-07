import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var exportURL: URL?
    @State private var importing = false
    @State private var confirmDelete = false
    @State private var notificationsAllowed = true

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
                Toggle("Attach location by default", isOn: Binding(get: { store.settings.attachLocationByDefault }, set: { v in
                    if v {
                        Task {
                            let ok = await model.location.requestAuthorization()
                            store.updateSettings { $0.attachLocationByDefault = ok; $0.locationPrompted = true }
                        }
                    } else {
                        store.updateSettings { $0.attachLocationByDefault = false }
                    }
                }))
                Toggle("“Still pooping?” reminder", isOn: binding(\.longSessionReminder))
            } header: {
                Text("POOPING")
            } footer: {
                Text("Location is only captured when a poop is logged, never in the background. Friends see locations attached to your poops until you edit or delete them.")
            }

            if !store.settings.blockedUserIDs.isEmpty {
                Section("BLOCKED") {
                    ForEach(store.settings.blockedUserIDs, id: \.self) { uid in
                        HStack {
                            Text(store.person(for: uid).map { "@" + $0.handle } ?? "Blocked person")
                            Spacer()
                            Button("Unblock") { store.unblock(uid) }
                        }
                    }
                }
            }

            Section {
                HStack {
                    Text("iCloud")
                    Spacer()
                    Text(model.availability.isAvailable ? "Connected" : (model.availability.message ?? "Checking…"))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                Button("Export my data") {
                    do { exportURL = try model.makeExport() } catch { model.error("Export failed", error) }
                }
                if let url = exportURL {
                    ShareLink(item: url) { Label("Share export (.zip)", systemImage: "square.and.arrow.up") }
                }
                Button("Import history (poop-history.json)") { importing = true }
            } header: {
                Text("YOUR DATA")
            } footer: {
                Text("Your data lives on this device and in your own iCloud. ShittyFriends has no server with your poop history.")
            }

            Section {
                Button("Delete all my data", role: .destructive) { confirmDelete = true }
            } footer: {
                Text("Deletes your history, groups you own and your shares from iCloud and this device. Your other devices on this iCloud account clear their copy too.")
            }

            Section("ABOUT") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                LabeledContent("Build", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1")
                Text(Copy.tagline).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("SETTINGS")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.notifications.refreshAuthorization()
            let s = model.notifications.authorization
            notificationsAllowed = s == .authorized || s == .provisional || s == .ephemeral
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
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
        .confirmationDialog("Delete everything?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete all my data", role: .destructive) {
                Task { await model.deleteAllMyData() }
            }
        } message: {
            Text("This can't be undone. Export first if you want a copy.")
        }
    }
}
