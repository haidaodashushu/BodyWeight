// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BodyWeightCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        .library(name: "WeightParsing", targets: ["WeightParsing"]),
        .executable(name: "ParserVerification", targets: ["ParserVerification"])
    ],
    targets: [
        .target(
            name: "WeightParsing",
            path: "BodyWeight/Services",
            exclude: ["PhotoOCRService.swift", "SpeechRecognitionService.swift"],
            sources: ["WeightTextParser.swift"]
        ),
        .executableTarget(
            name: "ParserVerification",
            dependencies: ["WeightParsing"],
            path: "Tests/ParserVerification"
        )
    ]
)
