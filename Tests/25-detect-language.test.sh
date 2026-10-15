#!/bin/sh
# Tests/25-detect-language.test.sh - "Detect language", the From picker's first option.
#
# The bundled langid names the source language, so the From picker no longer has to be right
# before Translate. Two things here are quietly wrong when broken. The From list now has one row
# in front of the To list, so a From index and a To index for the same language differ by one; any
# handler that resolves a From index through the To list translates from the language ABOVE the one
# the user picked. And langid answers in its own terms ("pt", "zh", or "zh-Hant" with
# --keep-script) while the app lists variants, so the answer has to be matched onto the app's
# codes - and refused, with a reason, when it names nothing this model translates.
#
# langid itself is a recorder here: its answers depend on the macOS NaturalLanguage model, and the
# binary is a build product that a fresh checkout does not have. Its own behavior is covered by
# `swift test` in Tools/langid.
. "${OMCTEST_LIB:?set OMCTEST_LIB, or run via: appletbuilder test}"
. "$OMCTEST_TESTS/lib.test.interp.sh"

# A text window with pickers for the given model, ready for a dispatch, From on Detect language.
open_text_window() { # <model-dir>
    reset_document
    omc_control_defaults interpreter.window
    omc_run interp.window.init
    printf '%s' "$1" > "$(spool_dir)/model.dir"
    interp_call populate_language_pickers "$(spool_dir)" >/dev/null 2>&1
    omc_control "$FROM_PICKER" 1
}

# detect_source_language's answer and status, as "rc|text".
detect() { # <to-code>
    local file
    file="$(make_text_file detect.src 'Some text.')"
    interp_eval "out=\$(detect_source_language '$(spool_dir)' '$1' '$file'); printf '%s|%s' \"\$?\" \"\$out\""
}

tg="$(make_mlx_model translategemma-12b-4bit)"

section "the libraries load without a word of output"
# Every handler sources them, and a stray top-level command prints its error into every handler's
# log while the handler itself goes on to pass every check here. Seen once, from an edit that
# landed a function body's lines at the top of lib.interp.sh.
check "sourcing prints nothing" "" "$(
    (
        . "$APP_SCRIPTS/lib.interp.sh"
        . "$APP_SCRIPTS/lib.interp.models.sh"
        . "$APP_SCRIPTS/lib.interp.transform.sh"
    ) 2>&1
)"

section "the From list starts with Detect language, persisted as auto"
open_text_window "$tg"
check "row 1 resolves to auto" "auto" "$(interp_call resolve_from_code "$(spool_dir)" 1)"
check "and auto is row 1"      "1"    "$(interp_call from_code_index "$(spool_dir)" auto)"
# The same language is one row lower in From than in To.
de_to="$(interp_call lang_code_index "$(spool_dir)" de)"
check "a language sits one row lower in From" "$((de_to + 1))" \
    "$(interp_call from_code_index "$(spool_dir)" de)"
check "To never offers Detect language" "no" \
    "$(contains "$(ui_prop "$TO_PICKER" options)" 'Detect language')"
check "auto is not a To code" "" "$(langcodes | /usr/bin/grep -x auto)"
omc_wait_for '[ "$(/bin/date +%s)" -gt "$(/bin/cat '"$(spool_dir)"'/lang_quiet 2>/dev/null || echo 0)" ]' 5
omc_fire interp.from.changed "$FROM_PICKER" 1
check "choosing it saves auto" "auto" "$(pref FromLang)"
reset_window
omc_control_defaults interpreter.window
omc_run interp.window.init
check "and a new window comes back on it" "1" "$(ui_value "$FROM_PICKER")"

section "langid is asked for a confident answer that keeps the script"
open_text_window "$tg"
fake_answer langid 0 'pl'
detect es >/dev/null
check "--keep-script" "yes" "$(fake_arg langid --keep-script)"
check "a confidence floor" "yes" "$(fake_arg langid --min-confidence)"
check "of 0.5" "0.5" "$(fake_argv langid | /usr/bin/sed -n '/^--min-confidence$/{n;p;}')"
check "on the file" "$OMCTEST_WORK/detect.src" "$(fake_argv langid | /usr/bin/sed -n '/^--file$/{n;p;}')"

section "an answer is matched onto the app's languages"
open_text_window "$tg"
fake_answer langid 0 'pl'
check "a plain code is taken as is" "0|pl" "$(detect es)"
fake_answer langid 0 'zh-Hant'
check "a script-tagged code too" "0|zh-Hant" "$(detect es)"
# An older langid ignores --keep-script and says "zh"; NaturalLanguage says "pt" for both kinds
# of Portuguese. The first listed variant wins...
fake_answer langid 0 'zh'
check "zh without a script is Simplified" "0|zh-Hans" "$(detect es)"
fake_answer langid 0 'pt'
check "pt is Portuguese (Brazil)" "0|pt-BR" "$(detect es)"
# ...unless it is the To language, when the other variant is the one that makes the request do
# something: Portuguese into Portuguese (Brazil) reads as a variant conversion.
check "but into Portuguese (Brazil) it is Portuguese (Portugal)" "0|pt-PT" "$(detect pt-BR)"
fake_answer langid 0 'zh'
check "and into Simplified Chinese it is Traditional" "0|zh-Hant" "$(detect zh-Hans)"
# Only the first line, and nothing but letters and hyphens, is ever looked at.
fake_answer langid 0 'de
fr'
check "only the first line counts" "0|de" "$(detect es)"

section "an answer that cannot be used is refused with a reason"
open_text_window "$tg"
fake_answer langid 1 ''
check "no confident answer" "1|Could not tell which language this is. Choose it under From." "$(detect es)"
fake_answer langid 0 'kk'
check "a language the app does not list" \
    "1|This text looks like a language Interpreter does not translate (kk). Choose it under From." \
    "$(detect es)"
fake_answer langid 0 'es'
check "the To language already" "1|This text is already in Spanish. Choose another To language." \
    "$(detect es)"
fake_answer langid 0 'pt'
check "a language with no other variant to fall back to" \
    "1|This text is already in Portuguese (Brazil). Choose another To language." \
    "$(/usr/bin/grep -v -x pt-PT "$(spool_dir)/langcodes.all" > "$OMCTEST_WORK/l.tmp"; /bin/mv "$OMCTEST_WORK/l.tmp" "$(spool_dir)/langcodes.all"; detect pt-BR)"
check "a missing langid is named as such, not blamed on the text" \
    "1|Language detection is missing from this copy of Interpreter. Choose the language under From." \
    "$(INTERP_LANGID_BIN="$OMCTEST_WORK/no-such-langid"; export INTERP_LANGID_BIN; detect es)"
hy="$(make_gguf_model hy-mt2-7b-q4)"
open_text_window "$hy"
fake_answer langid 0 'af'
check "a language the selected model does not translate" \
    "1|This text is in Afrikaans, which the selected model does not translate." "$(detect es)"

section "Translate with Detect language translates from the detected language"
open_text_window "$tg"
omc_control "$TO_PICKER" "$(interp_call lang_code_index "$(spool_dir)" de)"
omc_control "$SRC_EDITOR" "Dzien dobry, jak sie masz?"
fake_answer langid 0 'pl'
omc_trigger "$TRANSLATE_BTN"
omc_run interp.translate
check_status "the handler ran" 0
check "the job is from Polish" "yes" "$(job_says '"source_lang_code":"pl","target_lang_code":"de"')"
check "langid read the source text" "1" "$(fake_calls langid)"
check "the poller is told what was detected" "Polish" "$(spool_file from.detected)"
check "the status line says so" "Translating from Polish…" "$(ui_value "$STATUS_TEXT")"
check_absent "the scratch copy of the text is gone" "$(spool_dir)/detect.txt"

section "a chosen From language is used as is, and clears the note"
omc_control "$FROM_PICKER" "$(interp_call from_code_index "$(spool_dir)" en)"
omc_control "$SRC_EDITOR" "Hello there, how are you?"
fakes_reset
omc_run interp.translate
check "the job is from English" "yes" "$(job_says '"source_lang_code":"en"')"
check "langid was not asked" "0" "$(fake_calls langid)"
check_absent "the earlier detection is not reported for this job" "$(spool_dir)/from.detected"
check "the status line is the plain one" "Translating…" "$(ui_value "$STATUS_TEXT")"

section "Translate refuses text it cannot place, and gives the window back"
for answer in '1|' '0|de'; do
    open_text_window "$tg"
    omc_control "$TO_PICKER" "$(interp_call lang_code_index "$(spool_dir)" de)"
    omc_control "$SRC_EDITOR" "Guten Tag"
    fake_answer langid "${answer%%|*}" "${answer#*|}"
    omc_run interp.translate
    check_absent "nothing was published ($answer)" "$(spool_dir)/job.json"
    check "Translate is usable again ($answer)" "1" "$(ui_enabled "$TRANSLATE_BTN")"
    check "Swap too ($answer)"                  "1" "$(ui_enabled "$SWAP_BTN")"
    check "and Stop is off ($answer)"           "0" "$(ui_enabled "$STOP_BTN")"
done
check "the reason is in the status line" "This text is already in German. Choose another To language." \
    "$(ui_value "$STATUS_TEXT")"

section "a family prompted with language NAMES gets the detected one by name"
mm="$(make_mlx_model milmmt-46-12b-4bit)"
open_text_window "$mm"
omc_control "$TO_PICKER" "$(interp_call lang_code_index "$(spool_dir)" de)"
omc_control "$SRC_EDITOR" "Dzien dobry"
fake_answer langid 0 'pl'
omc_run interp.translate
check "MiLMMT is told the text is Polish" "yes" "$(job_says 'Translate this from Polish to German')"

section "Swap with Detect language swaps the detected language"
open_text_window "$tg"
omc_control "$TO_PICKER" "$(interp_call lang_code_index "$(spool_dir)" ja)"
omc_control "$SRC_EDITOR" "Dzien dobry"
omc_control "$TGT_EDITOR" "Konnichiwa"
fake_answer langid 0 'pl'
omc_run interp.swap
check "From became the old To" "ja" "$(interp_call resolve_from_code "$(spool_dir)" "$(ui_value "$FROM_PICKER")")"
check "To became the detected language" "pl" \
    "$(interp_call resolve_lang_code "$(spool_dir)" "$(ui_value "$TO_PICKER")")"
check "the panes swapped" "Konnichiwa" "$(ui_value "$SRC_EDITOR")"
check "both ways" "Dzien dobry" "$(ui_value "$TGT_EDITOR")"
check "saved as codes, From" "ja" "$(pref FromLang)"
check "and To" "pl" "$(pref ToLang)"

section "Swap with Detect language does nothing when the language cannot be named"
open_text_window "$tg"
pref_set FromLang auto
pref_set ToLang ja
omc_control "$TO_PICKER" "$(interp_call lang_code_index "$(spool_dir)" ja)"
omc_control "$SRC_EDITOR" "OK"
omc_control "$TGT_EDITOR" "OK"
ui_reset
fake_answer langid 1 ''
omc_run interp.swap
check "From was not touched" "0" "$(ui_calls "	$FROM_PICKER	")"
check "nor To" "0" "$(ui_calls "	$TO_PICKER	")"
check "nor the panes" "0" "$(ui_calls "	$SRC_EDITOR	")"
check "the preferences stand" "auto ja" "$(pref FromLang) $(pref ToLang)"
check "and the status line says why" "Could not tell which language this is. Choose it under From." \
    "$(ui_value "$STATUS_TEXT")"

section "Swap with Detect language and nothing to read says so"
open_text_window "$tg"
omc_control "$TO_PICKER" "$(interp_call lang_code_index "$(spool_dir)" ja)"
omc_control "$SRC_EDITOR" ""
omc_control "$TGT_EDITOR" ""
ui_reset
fakes_reset
omc_run interp.swap
check "langid was not asked" "0" "$(fake_calls langid)"
check "From was not touched" "0" "$(ui_calls "	$FROM_PICKER	")"
check "and the status line says why" "There is no text to detect the language of. Choose the From language to swap." \
    "$(ui_value "$STATUS_TEXT")"

section "the document window detects from the converted text"
doc="$(make_text_file lettre.txt 'Le chat dort sur le canape.')"
reset_document
make_mlx_model translategemma-12b-4bit >/dev/null
pb_set "${INTERP_PB_PREFIX}INTERP_DOC_INPUT_PATH" "$doc"
omc_control_defaults doc.window
omc_run interp.doc.init
printf '%s' "$(models_dir)/translategemma-12b-4bit" > "$(spool_dir)/model.dir"
omc_control "$FROM_PICKER" 1
omc_control "$TO_PICKER" "$(interp_call lang_code_index "$(spool_dir)" en)"
fake_answer langid 0 'fr'
omc_run interp.doc.translate
check "the job is from French" "yes" "$(job_says '"source_lang_code":"fr"')"
check "langid read the converted text" "$(spool_dir)/input.plain.txt" \
    "$(fake_argv langid | /usr/bin/sed -n '/^--file$/{n;p;}')"
check "the status line names it" "Translating from French…" "$(ui_value "$STATUS_TEXT")"
check "the output is still named for the To language" "$OMCTEST_WORK/lettre-en.txt" "$(output_path)"
/bin/rm -f "$(spool_dir)/job.json"
fake_answer langid 0 'en'
omc_run interp.doc.translate
check_absent "a document already in the To language is not translated" "$(spool_dir)/job.json"
check "and the status line says so" "This text is already in English. Choose another To language." \
    "$(ui_value "$STATUS_TEXT")"
check "Translate is usable again" "1" "$(ui_enabled "$TRANSLATE_BTN")"
check "and Stop is off"           "0" "$(ui_enabled "$STOP_BTN")"

section "a scanned PDF under Detect language is OCRed without a language hint"
scan_tool="$OMCTEST_WORK/pdfutil-scan"
cat > "$scan_tool" <<EOF
#!/bin/sh
case "\$1" in
    info) printf 'pages: 1\n' ;;
    text) exit 1 ;;
    ocr)  printf '%s\n' "\$@" > "$OMCTEST_WORK/ocr.argv"; printf 'Le chat dort.\n' ;;
esac
exit 0
EOF
/bin/chmod +x "$scan_tool"
scan="$(make_text_file scan.pdf '%PDF-1.7
1 0 obj')"
reset_document
make_mlx_model translategemma-12b-4bit >/dev/null
pb_set "${INTERP_PB_PREFIX}INTERP_DOC_INPUT_PATH" "$scan"
omc_control_defaults doc.window
omc_run interp.doc.init
printf '%s' "$(models_dir)/translategemma-12b-4bit" > "$(spool_dir)/model.dir"
omc_control "$TO_PICKER" "$(interp_call lang_code_index "$(spool_dir)" en)"
fake_answer langid 0 'fr'
saved_pdfutil="$INTERP_PDFUTIL_BIN"
INTERP_PDFUTIL_BIN="$scan_tool"; export INTERP_PDFUTIL_BIN
omc_control "$FROM_PICKER" 1
omc_run interp.doc.translate
check "OCR was asked without a language" "no" \
    "$(/usr/bin/grep -q -x -e '--lang' "$OMCTEST_WORK/ocr.argv" && echo yes || echo no)"
check "and the job is from the detected language" "yes" "$(job_says '"source_lang_code":"fr"')"
/bin/rm -f "$OMCTEST_WORK/ocr.argv"
omc_control "$FROM_PICKER" "$(interp_call from_code_index "$(spool_dir)" fr)"
omc_run interp.doc.translate
check "a chosen From language still hints OCR" "yes" \
    "$(/usr/bin/grep -q -x -e '--lang' "$OMCTEST_WORK/ocr.argv" && echo yes || echo no)"
INTERP_PDFUTIL_BIN="$saved_pdfutil"; export INTERP_PDFUTIL_BIN

reset_document
omctest_end
