// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TVMirror",
    platforms: [.macOS(.v13)],
    targets: [
        // The extra screen and the mini screen (Objective-C: uses undocumented macOS classes)
        .target(
            name: "VirtualDisplay",
            path: "Sources/VirtualDisplay",
            publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("QuartzCore"),
            ]
        ),
        .executableTarget(
            name: "TVMirror",
            dependencies: ["VirtualDisplay"],
            path: "Sources/TVMirror",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
            ]
        ),
    ]
)
