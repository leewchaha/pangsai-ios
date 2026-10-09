import CloudKit
import Foundation

enum CloudConfig {
    /// Must match the iCloud container in the entitlements and the Apple Developer portal.
    static let containerIdentifier = "iCloud.com.sakara.shittyfriends"
    /// Must match the App Group in both targets' entitlements.
    static let appGroup = "group.com.sakara.shittyfriends"

    /// Created on first use only. Creating a CKContainer without the iCloud entitlement throws an
    /// Objective-C exception, so nothing may touch this during unsigned simulator unit tests.
    static let container = CKContainer(identifier: containerIdentifier)

    /// True while the app is hosting XCTest (unsigned simulator builds have no iCloud entitlement).
    static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
    }

    /// Shared container directory used to hand the ping directory to the Notification Service Extension.
    static var appGroupDirectory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    /// Where local state lives (Application Support/ShittyFriends).
    static var localDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("ShittyFriends", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

extension ZoneRef {
    var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName == ZoneRef.currentUser ? CKCurrentUserDefaultName : ownerName)
    }

    init(_ zoneID: CKRecordZone.ID) {
        let owner = zoneID.ownerName == CKCurrentUserDefaultName ? ZoneRef.currentUser : zoneID.ownerName
        self.init(ownerName: owner, zoneName: zoneID.zoneName)
    }
}

extension RecordRef {
    var recordID: CKRecord.ID {
        CKRecord.ID(recordName: recordName, zoneID: zone.zoneID)
    }

    /// Which engine handles this record.
    var isPrivateDatabase: Bool { zone.isMine }
}

enum CloudDatabaseScope: String, Codable {
    case `private`, shared
}
