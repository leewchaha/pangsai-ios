import ActivityKit
import Foundation
import UIKit

/// Starts one native Live Activity per timed poop and ends it on DONE / undo.
/// The system timer keeps ticking after the app is suspended; no background loop.
@MainActor
final class PoopingLiveActivityCoordinator {
    private var observedID: UUID?
    private var observed = false
    private var observedPrivateMode: Bool?
    private var operation: Task<Void, Never>?

    func sync(event: PoopEvent?, cosmetic: CosmeticID, privateMode: Bool) {
        let next = event?.id
        if observed && observedID == next && observedPrivateMode == privateMode { return }
        observed = true
        observedID = next
        observedPrivateMode = privateMode
        operation?.cancel()
        operation = Task { [weak self] in
            guard let self else { return }
            await self.reconcile(event: event, cosmetic: cosmetic, privateMode: privateMode)
        }
    }

    private func reconcile(event: PoopEvent?, cosmetic: CosmeticID, privateMode: Bool) async {
        // Clean up orphaned activities after a relaunch or if the last session was undone.
        for activity in Activity<PoopingActivityAttributes>.activities {
            if activity.attributes.sessionID != event?.id.uuidString {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        guard !Task.isCancelled, let event else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let sessionID = event.id.uuidString
        if let current = Activity<PoopingActivityAttributes>.activities.first(where: { $0.attributes.sessionID == sessionID }) {
            if current.content.state.privateMode != privateMode {
                await current.update(ActivityContent(state: .init(imageReady: current.content.state.imageReady, privateMode: privateMode), staleDate: nil))
            }
            return
        }

        // Start immediately; Activity.request must not be delayed until after the
        // user backgrounds the app. A placeholder is shown while a cached 3D
        // snapshot renders, then a single state update loads the real PNG.
        let attributes = PoopingActivityAttributes(
            sessionID: sessionID,
            startedAt: event.startedAt,
            cosmeticID: cosmetic.rawValue
        )
        let appGroup = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.sakara.shittyfriends")
        let imageReady = appGroup.map {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("pooping-live-\(cosmetic.rawValue).png").path)
        } ?? false
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: .init(imageReady: imageReady, privateMode: privateMode), staleDate: nil),
                pushType: nil
            )
            guard !imageReady else { return }
            await publishSnapshot(cosmetic: cosmetic)
            guard !Task.isCancelled, observedID == event.id else { return }
            let fileExists = appGroup.map {
                FileManager.default.fileExists(atPath: $0.appendingPathComponent("pooping-live-\(cosmetic.rawValue).png").path)
            } ?? false
            if fileExists {
                await activity.update(ActivityContent(state: .init(imageReady: true, privateMode: privateMode), staleDate: nil))
            }
        } catch {
            // Live Activities can be disabled by the user. Session logging is unaffected.
            NSLog("ShittyFriends Live Activity unavailable: %@", String(describing: error))
        }
    }

    private func publishSnapshot(cosmetic: CosmeticID) async {
        guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.sakara.shittyfriends") else { return }
        let destination = dir.appendingPathComponent("pooping-live-\(cosmetic.rawValue).png")
        if FileManager.default.fileExists(atPath: destination.path) { return }
        let subject = RenderCache.Subject.poop(cosmetic)
        RenderCache.shared.request(subject)
        for _ in 0..<18 {
            if Task.isCancelled { return }
            if let img = RenderCache.shared.image(subject) {
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                let small = UIGraphicsImageRenderer(size: CGSize(width: 180, height: 180), format: format)
                    .image { _ in img.draw(in: CGRect(x: 0, y: 0, width: 180, height: 180)) }
                if let data = small.pngData() {
                    try? data.write(to: destination, options: .atomic)
                }
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}
