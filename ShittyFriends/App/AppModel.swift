import Foundation
import Observation
import SwiftUI
import UIKit
import os

private let log = Logger(subsystem: "com.sakara.shittyfriends", category: "app")

enum AppTab: String, CaseIterable, Hashable {
    case home, groups, calendar, you

    var title: String {
        switch self {
        case .home: return "HOME"
        case .groups: return "GROUPS"
        case .calendar: return "CALENDAR"
        case .you: return "YOU"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "map.fill"
        case .groups: return "person.3.fill"
        case .calendar: return "calendar"
        case .you: return "face.smiling.inverse"
        }
    }
}

/// Short-lived banner at the top of the screen.
struct Toast: Identifiable, Equatable {
    enum Style: Equatable { case achievement(AchievementID), cosmetic(CosmeticID), info, error, social }
    let id = UUID()
    var style: Style
    var title: String
    var body: String
}

/// A group invite waiting for the user's confirmation ("ASK TO JOIN?").
struct GroupJoinOffer: Identifiable {
    let id = UUID()
    var name: String
    var color: IdentityColor
    var object: GroupObject
    var code: String
}

/// Which full-screen experience is up.
enum ActiveSheet: Identifiable, Equatable {
    case friendInvite(FriendInvitePayload)
    case groupJoin(UUID)
    case pwmInvite(UUID)
    /// Watch (and react to) a Poop With Me session after my own DONE.
    case pwmWatch(UUID)
    case party(UUID)
    case highlights(HighlightPeriod, Date)
    /// Last week's highlights for one group (from a group highlights notification).
    case groupHighlights(ZoneRef)
    case profilePoster
    case signIn

    var id: String {
        switch self {
        case .friendInvite(let p): return "fi-" + p.t
        case .groupJoin(let id): return "gj-" + id.uuidString
        case .pwmInvite(let id): return "pwm-" + id.uuidString
        case .pwmWatch(let id): return "pwmw-" + id.uuidString
        case .party(let id): return "party-" + id.uuidString
        case .highlights(let p, let d): return "hl-\(p.rawValue)-\(d.timeIntervalSince1970)"
        case .groupHighlights(let z): return "ghl-" + z.description
        case .profilePoster: return "profile-poster"
        case .signIn: return "sign-in"
        }
    }
}

@MainActor
@Observable
final class AppModel {
    let store: Store
    @ObservationIgnored let persistence: FilePersistence
    let auth: AuthService
    @ObservationIgnored let sync: FirebaseSync
    @ObservationIgnored let social: SocialService
    @ObservationIgnored let push: PushService
    @ObservationIgnored let notifications: NotificationManager
    @ObservationIgnored let location: LocationService
    @ObservationIgnored let liveActivity = PoopingLiveActivityCoordinator()

    var availability: CloudAvailability = .unknown
    var tab: AppTab = .home
    var toasts: [Toast] = []
    var sheet: ActiveSheet?
    var groupOffers: [UUID: GroupJoinOffer] = [:]
    /// Live timed session cover.
    var showSession = false
    /// Poop With Me session to show on top of the live session.
    var openPWM: UUID?
    /// Short status for slow social operations ("Inviting…"). Never used for logging.
    var busy: String?
    var isForeground = true

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var didFinishInitialStart = false
    /// True while "Delete all my data" runs.
    @ObservationIgnored var isDeletingAll = false
    /// "is pooping" alerts wait out the Undo window, so a mis-tap never reaches anyone.
    @ObservationIgnored private var pendingPoopPings: [UUID: PingIntent] = [:]
    @ObservationIgnored private var lastPoopPingAt: Date?
    /// At most one poop alert per this many seconds: a burst of logs doesn't spam every friend.
    static let poopPingCooldown: TimeInterval = 120

    init() {
        let dir = FirebaseConfig.localDirectory
        let filePersistence = FilePersistence(directory: dir)
        persistence = filePersistence
        var localMy = filePersistence.loadMy()
        // Location-backed poop pins are a core Home experience now. Existing users who have never
        // made a location choice inherit the new default; an explicit previous choice is preserved.
        if !localMy.settings.locationPrompted {
            localMy.settings.attachLocationByDefault = true
        }
        store = Store(my: localMy, cache: filePersistence.loadCache())
        auth = AuthService()
        sync = FirebaseSync(store: store, directory: dir)
        social = SocialService(store: store)
        push = PushService(store: store)
        notifications = NotificationManager()
        location = LocationService()

        store.onDirty = { [weak self] _ in self?.scheduleSave() }
        store.onSessionChange = { [weak self] event in
            guard let self else { return }
            self.liveActivity.sync(event: event, cosmetic: self.store.profile.equippedCosmetic, privateMode: self.store.settings.lockScreenPrivate)
        }
        store.effectHandler = { [weak self] effect in self?.handle(effect) }
        sync.onAvailabilityChange = { [weak self] a in self?.availability = a }
        sync.onRemoteChangesApplied = { [weak self] in self?.remoteChangesApplied() }
        sync.onEvent = { [weak self] e in self?.handle(syncEvent: e) }
        auth.onChange = { [weak self] state in self?.authChanged(state) }
    }

    // MARK: - Lifecycle

    /// Idempotent; concurrent callers wait for the same start.
    func start() async {
        liveActivity.sync(event: store.liveEvent, cosmetic: store.profile.equippedCosmetic, privateMode: store.settings.lockScreenPrivate)
        if let startTask {
            await startTask.value
            return
        }
        let task = Task { await self.performStart() }
        startTask = task
        await task.value
        didFinishInitialStart = true
    }

    private func performStart() async {
        notifications.registerCategories()
        await notifications.refreshAuthorization()
        // Always register: alerts arrive through APNs/FCM; the token itself needs no alert permission.
        UIApplication.shared.registerForRemoteNotifications()
        FirebaseConfig.configure()
        push.start()
        push.writeDirectory()
        auth.start()
        if !FirebaseConfig.isConfigured { availability = .notConfigured }
        notifications.rescheduleSummaries(settings: store.settings, groups: store.groupSummaries)
        for p in store.parties() where store.myRSVP(p)?.response != .no { notifications.scheduleParty(p, settings: store.settings) }
    }

    /// Firebase Auth reported who is signed in (or that nobody is).
    private func authChanged(_ state: AuthService.State) {
        switch state {
        case .unknown:
            break
        case .signedOut:
            sync.stop()
            social.setUser(nil)
            push.setUser(nil)
            availability = FirebaseConfig.isConfigured ? .noAccount : .notConfigured
        case .signedIn(let uid, _):
            if let known = store.userID, known != UserID.localMe, known != uid {
                // A different account than the data on this device: start clean (the account's own
                // data streams back in through the listeners).
                log.info("account switched; resetting local state")
                sync.stop()
                store.resetForAccountChange(keepOnboarding: false)
                sync.resetLocalSyncState()
                persistence.wipe()
                UserDefaults.standard.removeObject(forKey: "sf.initialUploadDone")
            }
            store.setUserID(uid)
            social.setUser(uid)
            push.setUser(uid)
            sync.start(uid: uid)
            if !UserDefaults.standard.bool(forKey: "sf.initialUploadDone") {
                uploadEverythingMine()
                UserDefaults.standard.set(true, forKey: "sf.initialUploadDone")
            }
            Task { await social.syncBlocks(Set(store.settings.blockedUserIDs)) }
            scheduleRefresh(afterNanoseconds: 1_000_000_000)
        }
    }

    /// Queue every record I own (first sign-in, or after a reset): local-only history goes up.
    private func uploadEverythingMine() {
        let my = store.my
        var refs: [RecordRef] = []
        if my.profile != nil { refs.append(.profile) }
        refs += my.events.keys.map { .event($0) }
        refs += my.achievements.keys.map { .achievement($0) }
        refs += my.cosmetics.keys.map { .cosmetic($0) }
        refs.append(.settings)
        refs += my.friendLinks.keys.map { .friendLink($0) }
        refs += my.groupLinks.keys.map { .groupLink($0) }
        refs += my.invites.keys.map { .invite($0) }
        refs += my.spaceLinks.keys.map { .spaceLink($0) }
        for ref in refs { sync.save(ref) }
    }

    private func remoteChangesApplied() {
        // Parties may have just arrived: (re)schedule their reminders; groups may have changed.
        for p in store.parties() where store.myRSVP(p)?.response != .no { notifications.scheduleParty(p, settings: store.settings) }
    }

    private func handle(syncEvent e: FirebaseSync.Event) {
        switch e {
        case .friendRequest(let req):
            show(Toast(style: .social, title: "FRIEND REQUEST", body: "@\(req.person.handle) wants to be shitty friends."))
        case .friendshipConfirmed(let uid, let person):
            let handle = person?.handle ?? store.person(for: uid)?.handle ?? "friend"
            show(Toast(style: .social, title: "SHITTY FRIENDS", body: "You and @\(handle) can see each other's history now."))
        case .friendshipEnded:
            break
        case .requestDeclined(let uid):
            let handle = uid.flatMap { store.person(for: $0)?.handle } ?? "They"
            info("NOT THIS TIME", "\(handle == "They" ? "They" : "@" + handle) didn't accept. No hard feelings.")
        case .groupApproved(let gid):
            let name = store.my.groupLinks[gid]?.nameCache ?? "the group"
            show(Toast(style: .social, title: "YOU'RE IN \(name.uppercased())", body: "Group activity only. Full history stays between friends."))
            notifications.rescheduleSummaries(settings: store.settings, groups: store.groupSummaries)
        case .groupRequestEnded(let gid):
            _ = gid
            info("NOT LET IN", "The owner didn't approve your request.")
        case .removedFromGroup:
            info("GROUP GONE", "You were removed, or the owner deleted it.")
            notifications.rescheduleSummaries(settings: store.settings, groups: store.groupSummaries)
        }
    }

    /// Coalesces launch/foreground refreshes.
    private func scheduleRefresh(afterNanoseconds delay: UInt64 = 0) {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            guard let self else { return }
            defer { self.refreshTask = nil }
            guard !Task.isCancelled else { return }
            await self.refresh()
        }
    }

    /// Foreground / pull-to-refresh: flush writes, re-check listeners, clean up.
    func refresh() async {
        cleanupSpaces()
        sync.sendAll()
        sync.refreshListeners()
        store.repairMyGroupRecords()
        // Groups may have been created, joined or left: keep per-group highlight alerts current.
        notifications.rescheduleSummaries(settings: store.settings, groups: store.groupSummaries)
    }

    func enteredForeground() {
        isForeground = true
        liveActivity.sync(event: store.liveEvent, cosmetic: store.profile.equippedCosmetic, privateMode: store.settings.lockScreenPrivate)
        guard didFinishInitialStart else { return }
        scheduleRefresh()
    }

    func enteredBackground() {
        isForeground = false
        // iOS may suspend us before the Undo window ends; send what's still valid now.
        flushAllPoopPings()
        saveNow()
        sync.sendAll()
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        do {
            try persistence.save(my: store.my)
            try persistence.save(cache: store.cache)
        } catch {
            log.error("save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Effects

    private func handle(_ effect: Effect) {
        switch effect {
        case .save(let ref):
            sync.save(ref)
        case .delete(let ref):
            sync.delete(ref)
        case .ping(let intent):
            // Poop With Me / party invites and joins are pushed by the server when their records
            // land; only "is pooping" waits for the Undo window here.
            if case .poop(let eventID, _) = intent { queuePoopPing(intent, eventID: eventID) }
        case .cancelPings(let eventID):
            pendingPoopPings[eventID] = nil
        case .scheduleLongSessionReminder(let id, let at):
            notifications.scheduleLongSessionReminder(eventID: id, at: at, settings: store.settings)
        case .cancelLongSessionReminder(let id):
            notifications.cancelLongSessionReminder(eventID: id)
        case .scheduleParty(_, let partyID):
            if let p = store.party(partyID) { notifications.scheduleParty(p, settings: store.settings) }
        case .cancelParty(let id):
            notifications.cancelParty(id)
        case .requestLocation(let eventID):
            // Location is on by default for poop logs, but still requires the user's one-time iOS
            // permission. Ask contextually on the first located poop rather than during cold launch.
            Task { @MainActor [weak self] in
                guard let self else { return }
                let allowed: Bool
                if self.location.isAuthorized {
                    allowed = true
                    if !self.store.settings.locationPrompted {
                        self.store.updateSettings { $0.locationPrompted = true }
                    }
                } else if self.location.isDenied {
                    // Every poop is pinned; there is no in-app "off". Without iOS permission the poop
                    // simply has no pin (Settings shows how to turn location back on).
                    allowed = false
                    if !self.store.settings.locationPrompted {
                        self.store.updateSettings { $0.locationPrompted = true }
                    }
                } else {
                    allowed = await self.location.requestAuthorization()
                    self.store.updateSettings { $0.locationPrompted = true }
                }
                guard allowed else { return }
                self.location.locateOnce { [weak self] loc in
                    guard let self, let loc else { return }
                    self.store.attachLocation(loc, to: eventID)
                }
            }
        case .refreshSubscriptions:
            sync.refreshListeners()
        case .refreshDirectory:
            push.writeDirectory()
            Task { await social.syncBlocks(Set(store.settings.blockedUserIDs)) }
        case .rescheduleSummaries:
            notifications.rescheduleSummaries(settings: store.settings, groups: store.groupSummaries)
        case .achievementsUnlocked(let ids):
            for id in ids {
                show(Toast(style: .achievement(id), title: id.title.uppercased(), body: id.detail))
                if !isForeground && store.settings.notifyAchievements {
                    notifications.notifyNow(title: "🏆 \(id.title)", body: id.detail, settings: store.settings)
                }
            }
        case .cosmeticUnlocked(let id):
            show(Toast(style: .cosmetic(id), title: id.displayName.uppercased(), body: id.tagline))
        case .friendZoneGone(let uid):
            Task { await social.unfriend(uid) }
        case .ensureZone(let zone):
            sync.ensureZone(zone)
        case .haptic(let kind):
            Haptics.play(kind)
        }
    }

    // MARK: - Poop alerts

    private func queuePoopPing(_ intent: PingIntent, eventID: UUID) {
        pendingPoopPings[eventID] = intent
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((Store.undoWindow + 0.5) * 1_000_000_000))
            self?.flushPoopPing(eventID)
        }
    }

    private func flushPoopPing(_ eventID: UUID) {
        guard let intent = pendingPoopPings.removeValue(forKey: eventID) else { return }
        // Undone or deleted inside the window: nobody hears about it.
        guard let event = store.my.events[eventID] else { return }
        // A timer already stopped inside the window must not announce "is pooping".
        if case .poop(_, let kind) = intent, kind == .poopStart, !event.isLive { return }
        let now = Date()
        if let last = lastPoopPingAt, now.timeIntervalSince(last) < AppModel.poopPingCooldown { return }
        lastPoopPingAt = now
        sync.announce(eventID: eventID)
    }

    private func flushAllPoopPings() {
        for id in Array(pendingPoopPings.keys) { flushPoopPing(id) }
    }

    // MARK: - Presentation

    /// SwiftUI can't present a cover or sheet while another one is still animating away. Use this when
    /// the same tap closes a sheet and opens something else.
    func afterDismissal(_ action: @escaping @MainActor (AppModel) -> Void) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let self else { return }
            action(self)
        }
    }

    /// Opens the live session cover, waiting for a closing sheet first when needed.
    func presentSession(afterDismissal waits: Bool = false) {
        if waits || sheet != nil {
            sheet = nil
            afterDismissal { $0.showSession = true }
        } else {
            showSession = true
        }
    }

    // MARK: - Toasts

    func show(_ toast: Toast) {
        toasts.append(toast)
        let id = toast.id
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            self?.toasts.removeAll { $0.id == id }
        }
    }

    func info(_ title: String, _ body: String = "") { show(Toast(style: .info, title: title, body: body)) }

    func error(_ title: String, _ error: Error) {
        show(Toast(style: .error, title: title, body: userFacingErrorMessage(error)))
    }

    /// Never expose record ids, paths or server internals in the UI.
    func userFacingErrorMessage(_ error: Error) -> String {
        if let e = error as? SocialService.SocialError { return e.errorDescription ?? "That didn't work. Try again." }
        if let e = error as? AuthService.AuthError { return e.errorDescription ?? "Sign-in didn't work. Try again." }
        if let e = error as? SocialActionError { return e.errorDescription ?? "That didn't work. Try again." }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            return "No connection right now. Try again in a moment."
        }
        if let localized = error as? LocalizedError, let message = localized.errorDescription, !message.isEmpty {
            return message
        }
        log.error("operation failed: \(error.localizedDescription, privacy: .public)")
        return "Something went wrong. Try again."
    }

    // MARK: - Live polling

    /// Group / session records arrive through live listeners now; these stay as no-ops so screens
    /// keep their appear/disappear hooks (a one-shot fetch covers the notification-tap case).
    func startPolling(_ zone: ZoneRef, every seconds: Double = 4) {}
    func stopPolling(_ zone: ZoneRef) {}
    func startPresencePolling() {}
    func stopPresencePolling() {}
}
