// swift-tools-version:5.9
// Linux-only harness: builds the platform-independent Core of the app and runs its unit tests.
// The Xcode project (project.yml) does NOT use this file.
import PackageDescription

let package = Package(
    name: "ShittyFriendsCore",
    targets: [
        .target(name: "ShittyFriends", path: "Sources/ShittyFriends"),
        .testTarget(name: "ShittyFriendsTests", dependencies: ["ShittyFriends"], path: "Tests/ShittyFriendsTests")
    ]
)
