// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Branchyard",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Branchyard", targets: ["Branchyard"]),
    ],
    targets: [
        // Pure git logic: runs the git CLI and parses its output. No UI.
        .target(name: "GitCore"),
        // The app logo, drawn in code.
        .target(name: "BranchyardArt"),
        // The macOS SwiftUI app.
        .executableTarget(name: "Branchyard", dependencies: ["GitCore", "BranchyardArt"]),
        // Renders the logo into an .iconset (used by scripts/make-app.sh).
        .executableTarget(name: "IconRenderer", dependencies: ["BranchyardArt"]),
        // Self-check against throwaway repos: `swift run GitCoreCheck`.
        .executableTarget(name: "GitCoreCheck", dependencies: ["GitCore"]),
    ]
)
