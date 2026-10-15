#!/bin/sh
# Tests/75-transform-language.test.sh - the language of a text in the Text Transform windows.
#
# Two uses of the bundled langid. A preset may list the languages its model was made for (the
# Humanizer: English and Chinese), and a text clearly in another one is refused before the run
# rather than spending a minute on a rewrite the model was not trained for. And the post-run check
# reports a result that came back in another language - Polish in, English out - which the script
# check cannot see within one alphabet.
#
# Both are deliberately one-sided: a text langid will not place with confidence is let through and
# not judged, because a false alarm on a sound rewrite is worse than a missed one.
. "${OMCTEST_LIB:?set OMCTEST_LIB, or run via: appletbuilder test}"
. "$OMCTEST_TESTS/lib.test.interp.sh"

PRESETS="$APP_RESOURCES/Transformers"

# A langid that answers by a marker word in the file it is given, so a source and a result can be
# in different languages within one check.
lang_tool="$OMCTEST_WORK/langid-by-content"
/bin/cat > "$lang_tool" <<'EOF'
#!/bin/sh
file=""
while [ $# -gt 0 ]; do
    [ "$1" = --file ] && file="$2"
    shift
done
case "$(/bin/cat "$file")" in
    *POLSKI*) echo pl ;;
    *ENGLISH*) echo en ;;
    *NORSK*) echo nb ;;
    *CHINESE*) echo zh ;;
    *) exit 1 ;;
esac
EOF
/bin/chmod +x "$lang_tool"

# transform_check with the content-aware langid; prints the check line.
check_with_languages() { # <source text> <result text> [checks]
    local src res preset=""
    src="$(make_text_file lang.src "$1")"
    res="$(make_text_file lang.res "$2")"
    if [ -n "${3:-}" ]; then
        preset="$OMCTEST_WORK/lang.preset.json"
        printf '{ "id": "c", "name": "C", "family": "gemma4it", "checks": "%s" }\n' "$3" > "$preset"
    fi
    (
        INTERP_LANGID_BIN="$lang_tool"; export INTERP_LANGID_BIN
        interp_tcall transform_check "$src" "$res" "$OMCTEST_WORK/lang.check" $preset
    )
    /bin/cat "$OMCTEST_WORK/lang.check"
}

open_transform_window() {
    omc_control_defaults transform.window
    omc_run interp.transform.init
}

section "the Humanizer lists the languages it was trained on"
check "Humanize: English and Chinese" '["en","zh"]' \
    "$(/usr/bin/plutil -extract languages json -o - "$PRESETS/10-humanize.json" | /usr/bin/tr -d ' \n')"
check "the Gemma 4 presets take any language" "" \
    "$(for f in "$PRESETS"/[2-9]*.json; do /usr/bin/plutil -extract languages json -o - "$f" 2>/dev/null; done)"

section "a text clearly in another language is refused by Humanize"
reset_document
make_transform_model humanizer-12B-8bit >/dev/null
open_transform_window
check "the window starts on Humanize" "$PRESETS/10-humanize.json" "$(spool_file preset.file)"
omc_control "$SRC_EDITOR" "Dzien dobry, to jest dlugi tekst po polsku."
fake_answer langid 0 'pl'
omc_run interp.transform.run
check_absent "nothing was published" "$(spool_dir)/job.json"
check "the status line says why" "Humanize works on English and Chinese text, and this looks like Polish." \
    "$(ui_value "$STATUS_TEXT")"
check "Rewrite is usable again" "1" "$(ui_enabled "$TRANSLATE_BTN")"
check "and Stop is off" "0" "$(ui_enabled "$STOP_BTN")"
check "langid was asked for a confident, bare language" "yes no" \
    "$(fake_arg langid 0.8) $(fake_arg langid --keep-script)"
check_absent "the scratch copy of the text is gone" "$(spool_dir)/detect.txt"

section "English, Chinese, and text langid cannot place all go through"
for answer in '0|en' '0|zh' '1|'; do
    reset_document
    make_transform_model humanizer-12B-8bit >/dev/null
    open_transform_window
    omc_control "$SRC_EDITOR" "Some text to rewrite."
    fake_answer langid "${answer%%|*}" "${answer#*|}"
    omc_run interp.transform.run
    check_exists "a job was published ($answer)" "$(spool_dir)/job.json"
done

section "a preset without a language list never asks"
reset_document
make_transform_model gemma-4-12B-it-8bit >/dev/null
open_transform_window
printf '%s' "$PRESETS/20-fix-grammar.json" > "$(spool_dir)/preset.file"
omc_control "$SRC_EDITOR" "Dzien dobry."
fakes_reset
fake_answer langid 0 'pl'
omc_run interp.transform.run
check_exists "Fix grammar runs on Polish" "$(spool_dir)/job.json"
check "and langid was not consulted" "0" "$(fake_calls langid)"

section "the refusal names any number of languages"
three="$OMCTEST_WORK/three.json"
printf '{ "id": "t", "name": "Three", "family": "humanizer", "languages": ["en", "zh", "ja"] }\n' > "$three"
one="$OMCTEST_WORK/one.json"
printf '{ "id": "o", "name": "One", "family": "humanizer", "languages": ["en"] }\n' > "$one"
txt="$(make_text_file lang.txt 'Tekst.')"
fake_answer langid 0 'pl'
check "three" "Three works on English, Chinese and Japanese text, and this looks like Polish." \
    "$(interp_tcall transform_language_refusal "$three" "$txt")"
check "one" "One works on English text, and this looks like Polish." \
    "$(interp_tcall transform_language_refusal "$one" "$txt")"
tagged="$OMCTEST_WORK/tagged.json"
printf '{ "id": "z", "name": "Tagged", "family": "humanizer", "languages": ["en", "zh-Hant"] }\n' > "$tagged"
fake_answer langid 0 'zh'
check "a listed zh-Hant takes Chinese text, which langid calls zh" "" \
    "$(interp_tcall transform_language_refusal "$tagged" "$txt")"
fake_answer langid 0 'kk'
check "a language the app does not list is named by its code" "One works on English text, and this looks like kk." \
    "$(interp_tcall transform_language_refusal "$one" "$txt")"
check "a missing langid refuses nothing" "0" \
    "$(INTERP_LANGID_BIN="$OMCTEST_WORK/no-such-langid"; export INTERP_LANGID_BIN; interp_tcall transform_language_refusal "$one" "$txt" >/dev/null; echo $?)"

section "the document window refuses a document clearly in another language"
doc="$(make_text_file raport.txt 'To jest raport po polsku.')"
reset_document
make_transform_model humanizer-12B-8bit >/dev/null
pb_set "${INTERP_PB_PREFIX}INTERP_TDOC_INPUT_PATH" "$doc"
omc_control_defaults transform.doc.window
omc_run interp.tdoc.init
fake_answer langid 0 'pl'
omc_run interp.tdoc.run
check_absent "nothing was published" "$(spool_dir)/job.json"
check "langid read the converted text" "$(spool_dir)/input.plain.txt" \
    "$(fake_argv langid | /usr/bin/sed -n '/^--file$/{n;p;}')"
check "the status line says why" "Humanize works on English and Chinese text, and this looks like Polish." \
    "$(ui_value "$STATUS_TEXT")"
check "Rewrite is usable again" "1" "$(ui_enabled "$TRANSLATE_BTN")"
fake_answer langid 0 'en'
omc_run interp.tdoc.run
check_exists "an English document goes through" "$(spool_dir)/job.json"

section "the check reports a result in another language"
check "Polish in, English out" "Check: The result is in English, but the original is in Polish." \
    "$(check_with_languages 'POLSKI tekst.' 'ENGLISH text.')"
check "the same language is fine" "" \
    "$(check_with_languages 'POLSKI tekst.' 'POLSKI inny tekst.')"
check "a name with a non-ASCII letter survives" "Check: The result is in English, but the original is in Norwegian Bokmål." \
    "$(check_with_languages 'NORSK tekst.' 'ENGLISH text.')"
check "a text langid cannot place is not judged" "" \
    "$(check_with_languages 'POLSKI tekst.' 'something unclear')"
check "it joins the other findings" \
    "Check: The result is in English, but the original is in Polish; 1 number from the original is missing: 42." \
    "$(check_with_languages 'POLSKI tekst, 42 razy.' 'ENGLISH text, many times.')"
# The script check already says it, in its own words.
check "a switch to Chinese is reported once" "Check: The result switched to Chinese." \
    "$(check_with_languages 'ENGLISH text.' 'CHINESE 中文文本，内容很长。')"

section "a preset's checks can leave the language check out, or keep it"
check "numbers only: not reported" "" \
    "$(check_with_languages 'POLSKI tekst.' 'ENGLISH text.' 'numbers')"
check "language named: reported" "Check: The result is in English, but the original is in Polish." \
    "$(check_with_languages 'POLSKI tekst.' 'ENGLISH text.' 'numbers language')"
check "Make concise keeps it" "yes" \
    "$(contains "$(/usr/bin/plutil -extract checks raw -o - "$PRESETS/50-concise.json")" language)"

reset_document
omctest_end
