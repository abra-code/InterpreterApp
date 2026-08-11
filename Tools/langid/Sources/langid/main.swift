// langid - print the language of a document.
//
// A helper for Interpreter's translation pipeline, which needs the source language before it
// can pick a translation target or an OCR language hint, and currently asks the user for it.
//
// Designed to be called from shell, so the default output is the bare code and nothing else:
//
//     lang=$(langid --file "$doc") || lang=""
//
// --json gives the full picture (every candidate with its probability) for a caller that wants
// to decide for itself. Exit status is the quick answer: 0 identified, 1 not confident enough
// to say, 2 the call was wrong.
//
// See Sources/LanguageID/Detector.swift for why this is NaturalLanguage and not a model.

import Foundation
import LanguageID

let version = "1.0"

func usage() {
    let text = """
        langid \(version) - identify the language of text

        USAGE:
          langid [--text <text> | --file <path>] [options]
          cat file.txt | langid

        Reads stdin when neither --text nor --file is given.

        OPTIONS:
          --text <text>            text to identify
          --file <path>            file to identify (UTF-8; only the sampled prefix is read)
          --max-chars <n>          characters to READ (default 4000). This bounds I/O, not
                                   analysis: several windows spread across what is read are
                                   analyzed, so a foreign-language title or header cannot
                                   decide the answer on its own.
          --min-confidence <0..1>  refuse to answer below this (default 0, answer anything).
                                   Use it when a wrong guess is worse than no guess.
          --json                   full record: every candidate with its probability
          --version                print "langid <version>" and exit 0

        OUTPUT:
          By default the BCP-47 primary language subtag alone, e.g. "pl". Script and region are
          dropped: pl-PL and pl are one language for picking a translation target.

        EXIT STATUS:
          0  a language was identified
          1  undetermined, or below --min-confidence
          2  usage error (bad option, unreadable file)
        """
    print(text)
}

// MARK: - Arguments

let args = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("langid: \(message)\n".utf8))
    exit(2)
}

if args.contains("--version") {
    print("langid \(version)")
    exit(0)
}
if args.contains("--help") || args.contains("-h") {
    usage()
    exit(0)
}

// Validated, not clamped. A clamped typo identifies a one-character sample and answers with
// confidence: --max-chars 0 used to return "Catalan" for English text and exit 0.
var maxChars = 4000
if let raw = option("--max-chars") {
    guard let parsed = Int(raw), parsed > 0 else {
        fail("--max-chars must be a positive integer, got \"\(raw)\"")
    }
    maxChars = parsed
}

var minConfidence = 0.0
if let raw = option("--min-confidence") {
    guard let parsed = Double(raw), parsed >= 0, parsed <= 1 else {
        fail("--min-confidence must be between 0 and 1, got \"\(raw)\"")
    }
    minConfidence = parsed
}

// MARK: - Input

/// Read at most the first `maxChars` characters of a UTF-8 file.
///
/// Deliberately not `String(contentsOfFile:)`. That reads the whole file to keep 2000 characters
/// of it - a multi-GB log costs its size in memory - and it fails the WHOLE read when any byte
/// anywhere is not valid UTF-8, so a clean prefix followed by one stray byte (a truncated
/// download, a binary tail on a log) is rejected for an answer the prefix already determined.
///
/// The byte budget is 4x the character budget, UTF-8's maximum per scalar; the backoff then
/// drops up to three trailing bytes, the most a bounded read can slice off mid-sequence.
func readTextPrefix(path: String, maxChars: Int) -> String {
    guard FileManager.default.fileExists(atPath: path) else { fail("no such file: \(path)") }
    guard let handle = FileHandle(forReadingAtPath: path) else {
        fail("cannot open \(path) (permissions?)")
    }
    defer { try? handle.close() }

    guard let data = try? handle.read(upToCount: maxChars * 4 + 8), !data.isEmpty else {
        fail("cannot read \(path), or it is empty")
    }
    for drop in 0...min(3, data.count - 1) {
        if let decoded = String(data: data.prefix(data.count - drop), encoding: .utf8) {
            return decoded
        }
    }
    fail("\(path) is not UTF-8 text")
}

let source: String
if let text = option("--text") {
    source = text
} else if let path = option("--file") {
    source = readTextPrefix(path: path, maxChars: maxChars)
} else {
    // Stdin, so langid composes with the rest of the pipeline. Bounded the same way: a caller
    // piping a huge file should not make this hold it all.
    var data = Data()
    while data.count < maxChars * 4 + 8 {
        guard let chunk = try? FileHandle.standardInput.read(upToCount: 65536), !chunk.isEmpty
        else { break }
        data.append(chunk)
    }
    guard !data.isEmpty else {
        usage()
        exit(2)
    }
    var decoded: String? = nil
    for drop in 0...min(3, max(0, data.count - 1)) {
        if let s = String(data: data.prefix(data.count - drop), encoding: .utf8) {
            decoded = s
            break
        }
    }
    guard let decoded else { fail("stdin is not UTF-8 text") }
    source = decoded
}

// MARK: - Identify and report

let result = LanguageDetector.identify(source, maxCharacters: maxChars)

// Below the caller's floor is reported as no answer, not as a weak one: the whole point of
// --min-confidence is that the caller would rather have nothing than a guess.
let accepted: String? = {
    guard let code = result.code else { return nil }
    guard (result.confidence ?? 0) >= minConfidence else { return nil }
    return code
}()

if args.contains("--json") {
    var payload: [String: Any] = ["sampled_chars": result.sampledCharacters]
    if let accepted { payload["language"] = accepted }
    if let name = accepted.flatMap({ LanguageTag.englishName($0) }) { payload["name"] = name }
    // Confidence is PER MILLE (0-1000), not a fraction: JSONSerialization renders a Double by
    // its shortest round-trip form, so 0.994 serializes as 0.99399999999999999. Integers keep
    // the line readable, diffable and easy to compare in shell.
    if let confidence = result.confidence, accepted != nil {
        payload["confidence"] = Int((confidence * 1000).rounded())
    }
    payload["hypotheses"] = result.hypotheses.map {
        ["language": $0.code, "confidence": Int(($0.confidence * 1000).rounded())] as [String: Any]
    }
    if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
        print(String(decoding: data, as: UTF8.self))
    }
} else if let accepted {
    print(accepted)
}

exit(accepted == nil ? 1 : 0)
