// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Quotacat",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Quotacat",
            path: "Sources/Quotacat"
        )
    ]
)
