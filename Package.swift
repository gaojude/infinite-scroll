// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "InfiniteScroll",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
    ],
    targets: [
        .target(
            name: "InfiniteScrollProtocol",
            path: "Sources/InfiniteScrollProtocol"
        ),
        .executableTarget(
            name: "InfiniteScroll",
            dependencies: ["SwiftTerm", "InfiniteScrollProtocol"],
            path: "Sources/InfiniteScroll"
        ),
        .executableTarget(
            name: "infinite-scroll",
            dependencies: ["InfiniteScrollProtocol"],
            path: "Sources/InfiniteScrollCLI"
        ),
    ]
)
