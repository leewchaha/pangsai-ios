#if canImport(ActivityKit)
import ActivityKit
import Foundation

/// The Live Activity carries only a session identity, start time and cosmetic ID.
/// SwiftUI's native timer renders elapsed time while the app is suspended.
public struct PoopingActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var imageReady: Bool
        public var privateMode: Bool
        public init(imageReady: Bool = false, privateMode: Bool = false) {
            self.imageReady = imageReady
            self.privateMode = privateMode
        }
    }

    public var sessionID: String
    public var startedAt: Date
    public var cosmeticID: String

    public init(sessionID: String, startedAt: Date, cosmeticID: String) {
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.cosmeticID = cosmeticID
    }
}
#endif
