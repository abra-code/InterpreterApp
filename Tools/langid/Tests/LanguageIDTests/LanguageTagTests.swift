// LanguageTagTests.swift - the shapes a language answer actually arrives in.
//
// Every accepted input here is one a model or a caller has produced in practice, not a
// hypothetical: bare codes, cased codes, region-tagged codes, English names, quoted values,
// and values with trailing punctuation.

import Testing

@testable import LanguageID

@Suite("LanguageTag")
struct LanguageTagTests {

    @Test("a bare code passes through")
    func bareCode() {
        #expect(LanguageTag.normalize("pl") == "pl")
        #expect(LanguageTag.normalize("en") == "en")
        #expect(LanguageTag.normalize("ja") == "ja")
    }

    @Test("case is normalized")
    func caseInsensitive() {
        #expect(LanguageTag.normalize("PL") == "pl")
        #expect(LanguageTag.normalize("De") == "de")
    }

    @Test("region and script subtags are dropped")
    func dropsSubtags() {
        #expect(LanguageTag.normalize("pl-PL") == "pl")
        #expect(LanguageTag.normalize("en_US") == "en")
        #expect(LanguageTag.normalize("zh-Hant-TW") == "zh")
    }

    @Test("an English language name resolves to its code")
    func englishNames() {
        #expect(LanguageTag.normalize("Polish") == "pl")
        #expect(LanguageTag.normalize("polish") == "pl")
        #expect(LanguageTag.normalize("German") == "de")
        #expect(LanguageTag.normalize("Japanese") == "ja")
    }

    @Test("a qualified English name falls back to the language word")
    func qualifiedNames() {
        #expect(LanguageTag.normalize("Brazilian Portuguese") == "pt")
        #expect(LanguageTag.normalize("Simplified Chinese") == "zh")
    }

    @Test("surrounding quotes and punctuation are stripped")
    func stripsDecoration() {
        #expect(LanguageTag.normalize("\"pl\"") == "pl")
        #expect(LanguageTag.normalize("  fr.  ") == "fr")
        #expect(LanguageTag.normalize("'es'") == "es")
    }

    @Test("values meaning no answer return nil, not a language")
    func undetermined() {
        #expect(LanguageTag.normalize("und") == nil)
        #expect(LanguageTag.normalize("unknown") == nil)
        #expect(LanguageTag.normalize("none") == nil)
        #expect(LanguageTag.normalize("") == nil)
        #expect(LanguageTag.normalize("   ") == nil)
    }

    @Test("something that names no language returns nil")
    func nonsense() {
        #expect(LanguageTag.normalize("zzzz") == nil)
        #expect(LanguageTag.normalize("the document is in a language") == nil)
    }

    // Two detectors disagreeing over he/iw would be a reporting bug, not a real disagreement.
    @Test("legacy ICU aliases collapse onto the modern code")
    func legacyAliases() {
        #expect(LanguageTag.normalize("iw") == "he")
        #expect(LanguageTag.normalize("in") == "id")
        #expect(LanguageTag.normalize("ji") == "yi")
    }

    // The system model answers "no" and NLLanguageRecognizer answers "nb" for the same
    // Norwegian paragraph. Unfolded, that printed as a disagreement.
    @Test("Norwegian folds onto nb so the two detectors can be compared")
    func norwegianMacrolanguage() {
        #expect(LanguageTag.normalize("no") == "nb")
        #expect(LanguageTag.normalize("nb") == "nb")
        // Nynorsk carries the distinction itself and is left alone.
        #expect(LanguageTag.normalize("nn") == "nn")
    }

    // "no" must still be read as a code, not as the English word.
    @Test("a code is preferred over a same-spelled name")
    func codeWinsOverName() {
        #expect(LanguageTag.normalize("no") != nil)
        #expect(LanguageTag.normalize("it") == "it")
    }

    @Test("three-letter ISO codes resolve to their two-letter form")
    func alphaThreeCodes() {
        #expect(LanguageTag.normalize("pol") == "pl")
        #expect(LanguageTag.normalize("deu") == "de")
        #expect(LanguageTag.normalize("jpn") == "ja")
        #expect(LanguageTag.normalize("eng") == "en")
    }

    @Test("English names round-trip through englishName")
    func roundTrip() {
        #expect(LanguageTag.englishName("pl") == "Polish")
        #expect(LanguageTag.englishName("ja") == "Japanese")
    }
}
