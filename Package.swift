// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AppleMusicLyrics",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "AppleMusicLyrics",
            path: "Sources/AppleMusicLyrics"
        ),
        .testTarget(
            name: "AppleMusicLyricsTests",
            dependencies: ["AppleMusicLyrics"],
            path: "Tests/AppleMusicLyricsTests"
        )
    ]
)
