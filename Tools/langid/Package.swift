// swift-tools-version: 6.0
//
// langid - identify the language of a document. In-repo helper, not a separate project.
//
// It lives here rather than in its own repo (the way pdfutil and mlx-agent do) because it is
// two hundred lines over a system framework with no dependencies and no reuse outside this
// app. If a second app ever wants it, extracting it is a `git subtree` away.
//
// Split into a library plus a thin executable for the same reason mlx-agent keeps Chunking and
// AgentText separate: the part worth testing is the normalization of what a detector emits, and
// a library target lets `swift test` cover it in milliseconds without going through the CLI.

import PackageDescription

let package = Package(
    name: "langid",
    platforms: [
        // Matches pdfutil and the app itself. NaturalLanguage has shipped since 10.14, so this
        // is the app's floor rather than the framework's.
        .macOS(.v14)
    ],
    targets: [
        .target(name: "LanguageID"),
        .executableTarget(name: "langid", dependencies: ["LanguageID"]),
        .testTarget(name: "LanguageIDTests", dependencies: ["LanguageID"]),
    ]
)
