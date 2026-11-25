// swift-tools-version:6.0
import PackageDescription

// The Bridge desktop app. Built with the Command Line Tools alone:
// `swift build -c release`, packaged into Bridge.app by scripts/build-app.sh.
// SwiftTerm (the in-app terminal tab) is pinned to an exact release.
let package = Package(
    name: "Bridge",
    platforms: [.macOS(.v15)],
    dependencies: [.package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.11.2")],
    targets: [.executableTarget(
        name: "Bridge",
        dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
        path: "Sources/Bridge",
        swiftSettings: [.swiftLanguageMode(.v5)]
    )]
)
