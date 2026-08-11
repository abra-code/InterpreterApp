// Detector.swift - language identification over NaturalLanguage's NLLanguageRecognizer.
//
// WHY NOT A LANGUAGE MODEL. This was measured rather than assumed, on device, against Apple's
// Foundation Models system model asked the same question with a constrained output schema:
//
//   speed       3-4 ms here against 260-630 ms for the model, on identical inputs. Interpreter
//               would pay that per document for a question already answered.
//   confidence  this returns a real posterior over candidates ("es 0.994, ca 0.006"), which is
//               what lets a caller refuse a weak answer. The model returns a bare label; asking
//               it for a confidence produces a number it made up (it emitted 0.95 for
//               everything, including answers it got wrong).
//   footprint   no Apple Intelligence, no eligible hardware, no downloaded assets, no macOS 26.
//
// The two agreed on every language tried (English, German, Spanish, Japanese, Polish), so this
// is not a quality tradeoff - the model can do it, it is just the wrong tool. The general rule
// worth keeping: when a purpose-built framework already answers the question, it beats the LLM
// on speed, calibration and availability.

import Foundation
import NaturalLanguage

/// One candidate language and how much of the probability mass it holds.
public struct LanguageHypothesis: Sendable, Equatable {
    public let code: String
    public let confidence: Double

    public init(code: String, confidence: Double) {
        self.code = code
        self.confidence = confidence
    }
}

/// The result of identifying one piece of text.
public struct LanguageIdentification: Sendable, Equatable {
    /// Best guess, already normalized. Nil when the recognizer had no opinion.
    public let code: String?
    /// Confidence in `code`, 0...1. Nil when `code` is nil.
    public let confidence: Double?
    /// Every candidate including the winner, best first.
    public let hypotheses: [LanguageHypothesis]
    /// Characters actually examined.
    public let sampledCharacters: Int
}

public enum LanguageDetector {

    /// How much text one recognizer pass looks at. Chosen to sit comfortably above the
    /// recognizer's own internal appetite (see `identify`) without wasting characters.
    private static let windowSize = 600

    /// How many windows to spread across the document. Three is enough to stop a header
    /// deciding the answer, and costs about 10 ms in total.
    private static let windowCount = 3

    /// Identify the language of `text`, reading no more than `maxCharacters` of it.
    ///
    /// SAMPLES SEVERAL WINDOWS, NOT JUST THE HEAD, and that is the whole point of this function
    /// rather than calling NLLanguageRecognizer directly.
    ///
    /// NLLanguageRecognizer weights the START of what it is given far more heavily than the
    /// rest - measured, not assumed: a file of 200 characters of English followed by 19,600
    /// characters of Spanish was reported as English, and feeding it more text changed nothing
    /// (identical hypotheses at every budget from 1,500 to 9,000 characters). Whatever it does
    /// internally, the opening decides.
    ///
    /// That is wrong for real documents. A title, a byline, a citation, a code block or a
    /// markdown header in another language sits exactly where it does the most damage - this
    /// project's own English README was reported as DUTCH (0.567 against English 0.240) because
    /// its first 2,000 characters are mostly markup, paths and URLs. Interpreter converts to
    /// plain text before this runs, which helps, but headers and quotations survive conversion.
    ///
    /// So: take up to `windowCount` windows spread across the sampled text, run the recognizer
    /// on each, and average the per-language probabilities. A foreign-language opening then gets
    /// outvoted by the body instead of deciding for it.
    ///
    /// `maxCharacters` bounds READING, which is still worth doing - it is what stops a multi-GB
    /// file being pulled into memory - but it no longer meaningfully bounds analysis, because
    /// only the windows are analyzed.
    public static func identify(_ text: String, maxCharacters: Int = 4000) -> LanguageIdentification
    {
        let sample = String(text.prefix(max(1, maxCharacters)))
        guard !sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return LanguageIdentification(
                code: nil, confidence: nil, hypotheses: [], sampledCharacters: sample.count)
        }

        var totals: [String: Double] = [:]
        var analyzed = 0
        for window in windows(in: sample) {
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(window)
            let hypotheses = recognizer.languageHypotheses(withMaximum: 5)
            guard !hypotheses.isEmpty else { continue }
            analyzed += 1

            // Probabilities are SUMMED per normalized code, not just relabelled. The recognizer
            // hedges across script variants - four characters of Chinese came back as zh-Hant
            // 0.612 and zh-Hans 0.379 - so normalizing both to "zh" without folding would list
            // zh as its own alternative and report 0.612 for a language holding 0.991.
            for (language, probability) in hypotheses {
                let code = LanguageTag.normalize(language.rawValue) ?? language.rawValue
                totals[code, default: 0] += probability
            }
        }

        guard analyzed > 0 else {
            return LanguageIdentification(
                code: nil, confidence: nil, hypotheses: [], sampledCharacters: sample.count)
        }

        let ranked =
            totals
            .map { LanguageHypothesis(code: $0.key, confidence: $0.value / Double(analyzed)) }
            .sorted {
                // Ties broken by code so output is deterministic run to run; a dictionary's
                // iteration order is not, and this is consumed by scripts and tests.
                $0.confidence != $1.confidence
                    ? $0.confidence > $1.confidence : $0.code < $1.code
            }

        return LanguageIdentification(
            code: ranked.first?.code, confidence: ranked.first?.confidence, hypotheses: ranked,
            sampledCharacters: sample.count)
    }

    /// Up to `windowCount` evenly spread slices of `sample`, each at most `windowSize` long.
    ///
    /// Short text yields a single window covering all of it, so nothing changes for the common
    /// case of identifying a sentence.
    private static func windows(in sample: String) -> [String] {
        let characters = Array(sample)
        guard characters.count > windowSize else { return [sample] }

        // Spread the window STARTS across the whole sample, last one ending at the end. With
        // three windows over a long document that is beginning, middle and end - a foreign
        // header can then only ever be one vote of three.
        let span = characters.count - windowSize
        return (0..<windowCount).map { index in
            let start = windowCount == 1 ? 0 : span * index / (windowCount - 1)
            return String(characters[start..<min(start + windowSize, characters.count)])
        }
    }
}
