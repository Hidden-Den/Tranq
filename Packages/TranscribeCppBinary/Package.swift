// swift-tools-version:5.9
import PackageDescription

// Готовая сборка transcribe.cpp с Metal: движок GigaAM внутри процесса приложения.
// Чтобы обновить версию, поменяйте URL и контрольную сумму:
//   swift package compute-checksum TranscribeCpp.xcframework.zip
let package = Package(
    name: "TranscribeCppBinary",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CTranscribe", targets: ["CTranscribe"])
    ],
    targets: [
        .binaryTarget(
            name: "CTranscribe",
            url: "https://github.com/handy-computer/transcribe.cpp/releases/download/v0.4.2/TranscribeCpp.xcframework.zip",
            checksum: "650a42ee7836558d3047f328078be2b8a8d4c6e9f6a0a3f4ea145481ad1c1a86"
        )
    ]
)
