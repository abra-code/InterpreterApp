// DetectorTests.swift - identification behavior that callers depend on.
//
// These run the real NLLanguageRecognizer rather than a stub, because the thing worth pinning
// down is how this code treats the recognizer's output - the script-variant folding especially,
// which is invisible until you look at the hypothesis list.
//
// Kept to languages the recognizer is unambiguous about, and to properties rather than exact
// probabilities: the model behind NaturalLanguage belongs to the OS and its numbers may shift
// between releases. Asserting "zh wins and is not listed twice" survives that; asserting
// "zh == 0.991" would not.

import Testing

@testable import LanguageID

@Suite("LanguageDetector")
struct DetectorTests {

    @Test("identifies unambiguous samples")
    func identifiesCommonLanguages() {
        #expect(
            LanguageDetector.identify(
                "Last night I went to the shop to buy bread and milk, but it was already closed."
            ).code == "en")
        #expect(
            LanguageDetector.identify(
                "Gestern Abend ging ich zum Laden, um Brot und Milch zu kaufen, aber er war schon geschlossen."
            ).code == "de")
        #expect(
            LanguageDetector.identify(
                "Anoche fui a la tienda a comprar pan y leche, pero ya estaba cerrada."
            ).code == "es")
    }

    // The bug this exists to prevent: zh-Hant and zh-Hans arrive as separate hypotheses, and
    // normalizing without summing reported the winner's partial mass and listed zh twice.
    @Test("script variants fold into one entry holding the summed mass")
    func foldsScriptVariants() {
        let result = LanguageDetector.identify("我昨天去商店买面包和牛奶，但是商店已经关门了。")
        #expect(result.code == "zh")
        #expect(result.hypotheses.filter { $0.code == "zh" }.count == 1)
        let zh = result.hypotheses.first { $0.code == "zh" }
        #expect((zh?.confidence ?? 0) > 0.9)
    }

    @Test("hypotheses are ranked best first")
    func hypothesesRanked() {
        let result = LanguageDetector.identify(
            "Anoche fui a la tienda a comprar pan y leche, pero ya estaba cerrada.")
        let confidences = result.hypotheses.map { $0.confidence }
        #expect(confidences == confidences.sorted(by: >))
        #expect(result.hypotheses.first?.code == result.code)
    }

    @Test("the winner's confidence is the one reported for it")
    func confidenceMatchesWinner() {
        let result = LanguageDetector.identify(
            "Last night I went to the shop to buy bread and milk, but it was already closed.")
        let winner = result.hypotheses.first { $0.code == result.code }
        #expect(result.confidence == winner?.confidence)
    }

    @Test("empty and whitespace input yield no answer rather than a guess")
    func emptyInput() {
        #expect(LanguageDetector.identify("").code == nil)
        #expect(LanguageDetector.identify("   \n\t  ").code == nil)
        #expect(LanguageDetector.identify("").hypotheses.isEmpty)
    }

    @Test("only the requested prefix is examined")
    func honorsMaxCharacters() {
        let text = String(repeating: "a", count: 5000)
        #expect(LanguageDetector.identify(text, maxCharacters: 100).sampledCharacters == 100)
        // A zero or negative budget still samples one character rather than trapping; the CLI
        // rejects those before they get here, so this only guards library misuse.
        #expect(LanguageDetector.identify(text, maxCharacters: 0).sampledCharacters == 1)
    }

    // The reason identify() samples windows instead of the head. NLLanguageRecognizer weights
    // the start of its input so heavily that 200 characters of English decided a document whose
    // remaining 19,600 characters were Spanish.
    @Test("a foreign-language opening does not decide the answer")
    func openingDoesNotDominate() {
        let english = "Last night I walked to the corner shop to buy bread and milk. "
        let spanish = "Anoche fui a la tienda del barrio a comprar pan y leche para el desayuno. "
        let headed = String(english.prefix(200)) + String(repeating: spanish, count: 200)
        #expect(LanguageDetector.identify(headed, maxCharacters: 20000).code == "es")
    }

    // The mirror of the above: a real majority must still win, so the fix cannot simply be
    // "ignore the beginning".
    @Test("the majority language wins in a genuinely mixed document")
    func majorityWins() {
        let english = "Last night I walked to the corner shop to buy bread and milk. "
        let spanish = "Anoche fui a la tienda del barrio a comprar pan y leche. "
        let mixed = String(repeating: spanish, count: 15) + String(repeating: english, count: 90)
        #expect(LanguageDetector.identify(mixed, maxCharacters: 20000).code == "en")
    }

    @Test("short text is analyzed as a single window")
    func shortTextSingleWindow() {
        let short = "Anoche fui a la tienda a comprar pan y leche."
        let result = LanguageDetector.identify(short)
        #expect(result.code == "es")
        #expect(result.sampledCharacters == short.count)
    }

    @Test("identification is stable across repeated calls")
    func deterministic() {
        let text = "Anoche fui a la tienda a comprar pan y leche."
        let first = LanguageDetector.identify(text)
        for _ in 0..<5 {
            #expect(LanguageDetector.identify(text) == first)
        }
    }
}
