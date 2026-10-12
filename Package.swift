// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LightX2VAPP",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "LightX2VApp", targets: ["LightX2VApp"])],
    targets: [
        .target(name: "LightX2VCore", resources: [.copy("Resources/qwen_image_21_turbo.json"), .process("Resources/Localization")]),
        .executableTarget(name: "LightX2VApp", dependencies: ["LightX2VCore"], resources: [.copy("Resources/bridge.py"), .copy("Resources/prompt_enhancement.py"), .copy("Resources/requirements.txt")]),
        // Standalone checks also run with Command Line Tools (XCTest requires full Xcode).
        .executableTarget(name: "LightX2VCoreChecks", dependencies: ["LightX2VCore"], path: "Tests/LightX2VCoreTests"),
        .executableTarget(name: "LightX2VSetupChecks", dependencies: ["LightX2VCore"], path: "Tests/SetupChecks")
    ]
)
