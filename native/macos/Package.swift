// swift-tools-version:6.0
import PackageDescription

// The Bridge desktop app. Built with the Command Line Tools alone:
// `swift build -c release`, packaged into Bridge.app by scripts/build-app.sh.
let package = Package(
    name: "Bridge",
    platforms: [.macOS(.v15)],
    targets: [.executableTarget(name: "Bridge", path: "Sources/Bridge", swiftSettings: [.swiftLanguageMode(.v5)])]
)
