// LanguageTag.swift - normalize whatever names a language into a BCP-47 primary subtag.
//
// Pure and Foundation-only, in its own library target so `swift test` can cover it without
// going through the CLI.
//
// Two callers need it and they fail differently. NLLanguageRecognizer answers with its own
// NLLanguage raw values, which are mostly BCP-47 but include script-tagged forms
// (zh-Hans, zh-Hant) that have to fold together. And anything asking a language MODEL gets
// free text: the same question came back as "pl", "PL", "pl-PL", "Polish", "polish", and once
// as `"pl"` with the quotes included. Normalizing in one place is what lets two detectors be
// compared at all - see Private/commit-notes-langid.md for the measurements.
//
// The code/name table is derived from Locale rather than checked in. A hand-written table
// would be one more thing to keep current, and would silently disagree with the rest of the
// system about what "iw" or "in" mean (both are legacy codes ICU still resolves).

import Foundation

/// Canonicalizes language identifiers emitted by a model, a file, or a person.
public enum LanguageTag {

    /// English display name -> ISO code, built once from ICU's own tables.
    ///
    /// Lowercased keys, because the input case is not predictable. Where two codes share an
    /// English name the first one ICU lists wins; that is arbitrary but stable, and the codes
    /// involved are aliases of each other rather than genuinely different languages.
    private static let namesToCodes: [String: String] = {
        let english = Locale(identifier: "en_US")
        var map: [String: String] = [:]
        for code in Locale.LanguageCode.isoLanguageCodes {
            guard let name = english.localizedString(forLanguageCode: code.identifier) else {
                continue
            }
            let key = name.lowercased()
            if map[key] == nil { map[key] = code.identifier }
        }
        return map
    }()

    /// Every ISO language code, lowercased, for validating something that already looks like one.
    private static let knownCodes: Set<String> = {
        Set(Locale.LanguageCode.isoLanguageCodes.map { $0.identifier.lowercased() })
    }()

    /// Values that mean "no answer" rather than naming a language. Returned as nil so a caller
    /// can tell "the detector declined" from "the detector said English".
    ///
    /// "na" is deliberately in here even though it is also Nauru's ISO code: a detector that
    /// emits "na" means "not applicable" essentially every time, and Nauru is not a language
    /// any caller here will meet. `normalize("nauru")` still resolves, so only the two-letter
    /// spelling is lost.
    private static let undetermined: Set<String> = [
        "und", "unknown", "unk", "none", "n/a", "na", "null", "undetermined", "unclear",
    ]

    /// Normalize `raw` to a lowercase BCP-47 primary language subtag, or nil if it names nothing.
    ///
    /// Accepts a two- or three-letter code (`pl`, `PL`, `pol`), a tagged code (`pl-PL`,
    /// `zh_Hant_TW`), or an English
    /// language name (`Polish`, `polish`). Surrounding whitespace, quotes and trailing sentence
    /// punctuation are stripped first, because models add all three.
    ///
    /// The region and script are deliberately dropped. Callers here want to pick a translation
    /// target or an OCR language hint, and both are keyed by language; keeping `pl-PL` distinct
    /// from `pl` would only create two entries meaning one thing.
    public static func normalize(_ raw: String) -> String? {
        let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r\"'`.,;:!?()[]{}"))
            .lowercased()
        guard !cleaned.isEmpty, !undetermined.contains(cleaned) else { return nil }

        // A code, possibly with a script/region attached: take the primary subtag.
        //
        // Aliases are resolved BEFORE validation, not after. ICU's modern code list does not
        // contain "iw"/"in"/"ji" at all - they are the superseded spellings - so checking
        // membership first would reject them as unknown and never reach the mapping.
        let primary = cleaned.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)
        if let primary {
            let mapped = canonical(primary)
            if knownCodes.contains(mapped) { return mapped }

            // An alpha-3 code (pol, deu, jpn). ICU's isoLanguageCodes lists only the shortest
            // canonical spelling per language, so no three-letter form of a language that has a
            // two-letter code is ever in `knownCodes` - but the display-name API still resolves
            // one. Going out to the name and back in is what turns "pol" into "pl".
            //
            // The guard matters: for an unknown code ICU echoes the input back as its own
            // "name", so without comparing them "zzzz" would resolve to itself.
            if let name = Locale(identifier: "en_US").localizedString(forLanguageCode: mapped),
                name.lowercased() != mapped, let byCode = namesToCodes[name.lowercased()]
            {
                return canonical(byCode.lowercased())
            }
        }

        // An English language name. Checked after the code path so a two-letter name could
        // never shadow a code, and on the whole cleaned string so "haitian creole" resolves.
        if let byName = namesToCodes[cleaned] {
            return canonical(byName.lowercased())
        }

        // A name with a qualifier the table does not carry verbatim ("brazilian portuguese",
        // "simplified chinese"). Fall back to the last word, which is the language in English
        // for every such construction.
        if let lastWord = cleaned.split(separator: " ").last.map(String.init),
            lastWord != cleaned, let byWord = namesToCodes[lastWord]
        {
            return canonical(byWord.lowercased())
        }

        return nil
    }

    /// Collapse ICU's legacy aliases onto the codes the rest of the system uses.
    ///
    /// ICU still resolves `iw`/`in`/`ji`, and a model that learned from older text will
    /// occasionally emit one. Mapping them here means a caller comparing two detectors does
    /// not see a spurious disagreement between `he` and `iw`.
    ///
    /// `no` -> `nb` is the same problem in a case that actually turns up: Norwegian is in the
    /// system model's supported set, the model answers `no` (the macrolanguage), and
    /// NLLanguageRecognizer answers `nb` (Bokmal). Comparing the two without folding reported a
    /// disagreement on ordinary Norwegian text. CLDR's own languageAlias maps `no` to `nb`, so
    /// that is the direction taken. The cost is real and accepted: a bare `no` over Nynorsk
    /// prose is now labelled `nb`. Nothing here can do better, because `no` does not carry the
    /// distinction - a detector that means Nynorsk says `nn`, which is left alone.
    private static func canonical(_ code: String) -> String {
        switch code {
        case "iw": return "he"
        case "in": return "id"
        case "ji": return "yi"
        case "mo": return "ro"
        case "no": return "nb"
        default: return code
        }
    }

    /// The English name for a code, for printing. Nil when the code names nothing.
    public static func englishName(_ code: String) -> String? {
        Locale(identifier: "en_US").localizedString(forLanguageCode: code)
    }
}
