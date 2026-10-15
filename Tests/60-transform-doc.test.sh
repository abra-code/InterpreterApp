#!/bin/sh
# Tests/60-transform-doc.test.sh - the Text Transform document window.
#
# It writes FILES, like the translator's document window, so the same two risks lead: the output
# path (named after the PRESET here, never overwriting a file the user already has) and the
# judgement about whether a document could be read. The output helpers themselves are shared with
# the translator and covered in 30-document; what is checked here is that this window feeds them
# the preset's suffix, follows a preset switch, and keeps its handoff apart from the translator's.
#
# Not covered: the poller's transform-doc delivery (a background worker), which reuses the
# document mode delivery covered in 30-document.
. "${OMCTEST_LIB:?set OMCTEST_LIB, or run via: appletbuilder test}"
. "$OMCTEST_TESTS/lib.test.interp.sh"

# A second preset with no output_suffix, and one whose suffix tries to be a path.
TEST_PRESETS="$OMCTEST_WORK/presets"
/bin/mkdir -p "$TEST_PRESETS"
/bin/cp "$APP_RESOURCES/Transformers/10-humanize.json" "$TEST_PRESETS/10-humanize.json"
cat > "$TEST_PRESETS/20-plain.json" <<'EOF'
{ "id": "plain", "name": "Plain", "family": "humanizer", "button": "Go", "notice": "Plain.",
  "sampling": { "temperature": 0.5, "top_p": 1.0, "max_new_tokens": 512 },
  "job": { "output": "stitch", "budget_tokens": 300, "prompt": "{{chunk}}" } }
EOF
cat > "$TEST_PRESETS/30-sneaky.json" <<'EOF'
{ "id": "sneaky", "name": "Sneaky", "family": "humanizer", "output_suffix": "../evil name",
  "sampling": { "temperature": 0.5, "top_p": 1.0, "max_new_tokens": 512 },
  "job": { "output": "stitch", "budget_tokens": 300, "prompt": "{{chunk}}" } }
EOF

use_test_presets() { INTERP_PRESETS_DIR="$TEST_PRESETS"; export INTERP_PRESETS_DIR; }
use_shipped_presets() { unset INTERP_PRESETS_DIR; }

# Open the window on a file, the way both routes into it do: through its own handoff key.
open_tdoc_window() { # <input-path>
    reset_document
    make_transform_model humanizer-12B-8bit >/dev/null
    pb_set "${INTERP_PB_PREFIX}INTERP_TDOC_INPUT_PATH" "$1"
    omc_control_defaults transform.doc.window
    omc_run interp.tdoc.init
}

pick_preset() { # <1-based index>
    printf '0' > "$(spool_dir)/preset_quiet"
    omc_control "$PRESET_PICKER" "$1"
    omc_run interp.transform.preset.changed
}

section "the window opens on the handed-off document, in transform-doc mode"
use_shipped_presets
doc="$(make_text_file report.txt 'It is worth noting that the report is long.')"
open_tdoc_window "$doc"
check_status "init ran" 0
check "the input path was recorded" "$doc" "$(input_path)"
check "and shown" "$doc" "$(ui_value "$INPUT_PATH_TEXT")"
check "the original is previewed" "$doc" "$(ui_value "$QL_INPUT")"
check "the window is in transform-doc mode" "transform-doc" "$(spool_file mode)"
wait_for_calls interp.poll.sh 1
# The mode makes the shared poller run the transform model logic AND write the result to a file.
check "and the poller was told so" "transform-doc" "$(fake_arg_at interp.poll.sh 3)"
check "the Transform picker is filled" '["Humanize","Fix grammar","Make formal","Make casual","Make concise","Simplify","Summarize"]' \
    "$(ui_prop "$PRESET_PICKER" options)"
check "the output is named after the preset" "$OMCTEST_WORK/report-humanized.txt" "$(output_path)"
check "and shown" "$OMCTEST_WORK/report-humanized.txt" "$(ui_value "$OUTPUT_PATH_TEXT")"
check "nothing is previewed yet" "" "$(ui_value "$QL_OUTPUT")"
check "Rewrite starts off" "0" "$(ui_enabled "$TRANSLATE_BTN")"
check "the button carries the preset's title" "Rewrite" "$(ui_prop "$TRANSLATE_BTN" title)"
check "with a model installed, no chooser opens" "0" "$(chain_asked interp.tmodels)"

section "the handoff is consumed, and is not the translator's"
check "the key was cleared" "" "$(tdoc_handoff)"
reset_window
omc_run interp.tdoc.init
check "a window opened with no handoff says so" "No input document." "$(ui_value "$STATUS_TEXT")"
check "and has no output to name" "" "$(output_path)"
# A translator handoff waiting on its own key must not be taken by this window.
reset_document
pb_set "${INTERP_PB_PREFIX}INTERP_DOC_INPUT_PATH" "$doc"
omc_control_defaults transform.doc.window
omc_run interp.tdoc.init
check "the translator's handoff is left alone" "$doc" "$(doc_handoff)"
check "and this window did not open on it" "" "$(input_path)"

section "with no model of the preset's family, the transform chooser opens"
reset_document
use_shipped_presets
pb_set "${INTERP_PB_PREFIX}INTERP_TDOC_INPUT_PATH" "$doc"
omc_control_defaults transform.doc.window
omc_run interp.tdoc.init
check "the transform chooser was asked for" "1" "$(chain_asked interp.tmodels)"
check "not the translation one" "0" "$(chain_asked interp.models)"

section "an existing file is never overwritten, and a preset switch renames the output"
use_test_presets
doc="$(make_text_file memo.txt 'Some text.')"
printf 'an earlier rewrite\n' > "$OMCTEST_WORK/memo-humanized.txt"
open_tdoc_window "$doc"
check "a taken name is skipped" "$OMCTEST_WORK/memo-humanized-1.txt" "$(output_path)"
check "the earlier file is untouched" "an earlier rewrite" "$(/bin/cat "$OMCTEST_WORK/memo-humanized.txt")"
pick_preset 2
check "a preset without a suffix gets 'rewritten'" "$OMCTEST_WORK/memo-rewritten.txt" "$(output_path)"
check "and the window shows it" "$OMCTEST_WORK/memo-rewritten.txt" "$(ui_value "$OUTPUT_PATH_TEXT")"
# The Humanize output this window already settled on comes back, existing or not, rather than a
# third name being minted.
printf 'its own earlier result\n' > "$OMCTEST_WORK/memo-humanized-1.txt"
pick_preset 1
check "switching back reuses this window's file" "$OMCTEST_WORK/memo-humanized-1.txt" "$(output_path)"
check "which is previewed again" "$OMCTEST_WORK/memo-humanized-1.txt" "$(ui_value "$QL_OUTPUT")"
check "with Reveal on" "1" "$(ui_enabled "$REVEAL_OUTPUT_BTN")"
pick_preset 3
check "a suffix cannot leave the folder or carry spaces" "$OMCTEST_WORK/memo-evilname.txt" "$(output_path)"
/bin/rm -f "$OMCTEST_WORK/memo-humanized.txt" "$OMCTEST_WORK/memo-humanized-1.txt"

section "Rewrite converts the document and publishes the preset's job"
use_shipped_presets
doc="$(make_text_file source.txt 'It is important to note that the cat sleeps on the sofa.')"
open_tdoc_window "$doc"
"$OMC_OMC_SUPPORT_PATH/omc_dialog_control" "$OMC_ACTIONUI_WINDOW_UUID" "$CHECK_TEXT" "Check: stale."
omc_run interp.tdoc.run
check_status "the handler ran" 0
check_exists "a job was published" "$(spool_dir)/job.json"
# textutil runs for real, as in 30-document: it is the conversion the window depends on.
check "the converted text reached the job" "It is important to note that the cat sleeps on the sofa." \
    "$(spool_file source.1.txt | /usr/bin/sed -e 's/[[:space:]]*$//')"
check "the prompt is the preset's" \
    "$(/usr/bin/plutil -extract job.prompt raw -o - "$APP_RESOURCES/Transformers/10-humanize.json")" \
    "$(/usr/bin/plutil -extract prompt raw -o - "$(spool_dir)/job.json")"
check "the destination was captured for this job" "$OMCTEST_WORK/source-humanized.txt" "$(spool_file job.output.path)"
check "Rewrite went off" "0" "$(ui_enabled "$TRANSLATE_BTN")"
check "Stop came on" "1" "$(ui_enabled "$STOP_BTN")"
check "Reveal went off" "0" "$(ui_enabled "$REVEAL_OUTPUT_BTN")"
check "the previous check line was cleared" "" "$(ui_value "$CHECK_TEXT")"
check "the status line says so" "Rewriting..." "$(ui_value "$STATUS_TEXT")"
check_absent "the dispatch lock was released" "$(spool_dir)/dispatch.lock"

section "a preset switch during a run does not retarget the run's output"
use_test_presets
open_tdoc_window "$doc"
omc_run interp.tdoc.run
check "the job writes to the Humanize name" "$OMCTEST_WORK/source-humanized.txt" "$(spool_file job.output.path)"
pick_preset 2
check "the next run would write elsewhere" "$OMCTEST_WORK/source-rewritten.txt" "$(output_path)"
check "the job in flight is unmoved" "$OMCTEST_WORK/source-humanized.txt" "$(spool_file job.output.path)"

section "an empty document is refused with an alert"
use_shipped_presets
doc="$(make_text_file blank.txt '
   ')"
open_tdoc_window "$doc"
omc_run interp.tdoc.run
check_absent "nothing was published" "$(spool_dir)/job.json"
check "the status line says why" "No text in this document." "$(ui_value "$STATUS_TEXT")"
check "and the user was told" "No text found" "$(ui_alert_title)"
check "Rewrite is usable again" "1" "$(ui_enabled "$TRANSLATE_BTN")"
check "and Stop went off" "0" "$(ui_enabled "$STOP_BTN")"

section "a document that cannot be read is refused, and says so"
pages="$OMCTEST_WORK/Keynote.pages"
/bin/mkdir -p "$pages"
printf 'not really a pages file\n' > "$pages/index.xml"
open_tdoc_window "$pages"
omc_run interp.tdoc.run
check_absent "nothing was published" "$(spool_dir)/job.json"
check "the status line says so" "Could not read this document." "$(ui_value "$STATUS_TEXT")"
check "and an alert names the problem" "Can't read this document" "$(ui_alert_title)"

section "Rewrite with no input or no preset publishes nothing"
reset_document
omc_control_defaults transform.doc.window
omc_run interp.tdoc.init
omc_run interp.tdoc.run
check_absent "no input document, no job" "$(spool_dir)/job.json"
check "and it says so" "No input document." "$(ui_value "$STATUS_TEXT")"
doc="$(make_text_file nopreset.txt 'Text.')"
open_tdoc_window "$doc"
/bin/rm -f "$(spool_dir)/preset.file"
omc_run interp.tdoc.run
check_absent "no preset, no job" "$(spool_dir)/job.json"
check "and it says so" "Choose a transform first." "$(ui_value "$STATUS_TEXT")"

section "Choose... is remembered against the preset, and survives a switch away and back"
use_test_presets
doc="$(make_text_file chosen.txt 'Text.')"
open_tdoc_window "$doc"
elsewhere="$OMCTEST_WORK/Elsewhere/my-rewrite.txt"
/bin/mkdir -p "$OMCTEST_WORK/Elsewhere"
omc_dialog_answer save_as "$elsewhere"
omc_run interp.tdoc.choose.output
check "the new path was recorded" "$elsewhere" "$(output_path)"
check "and shown" "$elsewhere" "$(ui_value "$OUTPUT_PATH_TEXT")"
omc_dialog_answer save_as ""
omc_run interp.tdoc.choose.output
check "cancelling leaves it alone" "$elsewhere" "$(output_path)"
pick_preset 2
check "another preset derives its own name" "$OMCTEST_WORK/chosen-rewritten.txt" "$(output_path)"
pick_preset 1
check "and coming back restores the choice" "$elsewhere" "$(output_path)"

section "File > Open for Text Transform and the file service open this window"
reset_document
doc="$(make_text_file opened.txt 'Text.')"
omc_dialog_answer choose_file "$doc"
omc_run interp.tdoc.open
check "the transform document window is opened" "1" "$(chain_asked interp.tdoc)"
check "with the file on its own handoff" "$doc" "$(tdoc_handoff)"
check "and not on the translator's" "" "$(doc_handoff)"
reset_document
omc_dialog_answer choose_file ""
omc_run interp.tdoc.open
check "a cancelled panel opens nothing" "0" "$(chain_asked interp.tdoc)"
reset_document
omc_object "$doc"
omc_run interp.service.transform.file
check "the service opens it too" "1" "$(chain_asked interp.tdoc)"
check "with the file handed over" "$doc" "$(tdoc_handoff)"
reset_document
omc_object "$OMCTEST_WORK"
omc_run interp.service.transform.file
check "a folder is ignored" "0" "$(chain_asked interp.tdoc)"
# An RTFD document is a package - a folder - and is one of the types the service is offered for.
rtfd="$OMCTEST_WORK/Notes.rtfd"
/bin/mkdir -p "$rtfd"
printf '{\\rtf1 Text.}\n' > "$rtfd/TXT.rtf"
reset_document
omc_object "$rtfd"
omc_run interp.service.transform.file
check "an RTFD package is opened" "1" "$(chain_asked interp.tdoc)"
check "with the package handed over" "$rtfd" "$(tdoc_handoff)"
/bin/rm -rf "$rtfd"

section "a scanned PDF with no language hint is OCRed with language detection"
# pdf_ocr_page has no branch for "lang mode with an empty hint", so before the fix every scanned
# page of a transform document failed. A fake pdfutil that knows the three verbs: one page, no text
# layer, and OCR that records how it was asked.
scan_tool="$OMCTEST_WORK/pdfutil-scan"
cat > "$scan_tool" <<EOF
#!/bin/sh
case "\$1" in
    info) printf 'pages: 1\n' ;;
    text) exit 1 ;;
    ocr)  printf '%s\n' "\$@" > "$OMCTEST_WORK/ocr.argv"; printf 'Recognized words.\n' ;;
esac
exit 0
EOF
/bin/chmod +x "$scan_tool"
/bin/mkdir -p "$(spool_dir)"
pdf_out="$OMCTEST_WORK/scan.txt"
rc="$(INTERP_PDFUTIL_BIN="$scan_tool" interp_eval "pdf_extract_text '$OMCTEST_WORK/scan.pdf' '$pdf_out' '$(spool_dir)' ''; echo \$?")"
check "the page ladder succeeded" "0" "$rc"
check "the OCR text came through" "Recognized words." "$(/usr/bin/sed -e 's/[[:space:]]*$//' "$pdf_out" | /usr/bin/grep -v '^$')"
check "OCR was asked without a language" "no" \
    "$(/usr/bin/grep -q -x -e '--lang' "$OMCTEST_WORK/ocr.argv" && echo yes || echo no)"
# The page count sits right before a non-ASCII ellipsis, which bash 3.2 once swallowed it into.
check "the progress names the page count" "yes" \
    "$(ui_value "$STATUS_TEXT" | /usr/bin/grep -q 'page 1 of 1' && echo yes || echo no)"
# The translator's path still hints its From language.
/bin/rm -f "$OMCTEST_WORK/ocr.argv" "$pdf_out"
rc="$(INTERP_PDFUTIL_BIN="$scan_tool" interp_eval "pdf_extract_text '$OMCTEST_WORK/scan.pdf' '$pdf_out' '$(spool_dir)' 'fr'; echo \$?")"
check "with a hint it still succeeds" "0" "$rc"
check "and passes the language" "yes" \
    "$(/usr/bin/grep -q -x -e '--lang' "$OMCTEST_WORK/ocr.argv" && echo yes || echo no)"

section "a preset switch while a scanned PDF is being read stops the run"
# The fake pdfutil's OCR step plays the user: it switches the window's preset mid-conversion.
use_test_presets
scan="$OMCTEST_WORK/scanned.pdf"
printf '%%PDF-1.4\nnot really a pdf\n' > "$scan"
open_tdoc_window "$scan"
switcher="$OMCTEST_WORK/pdfutil-switch"
cat > "$switcher" <<EOF2
#!/bin/sh
case "\$1" in
    info) printf 'pages: 1\n' ;;
    text) exit 1 ;;
    ocr)  printf '%s' "$TEST_PRESETS/20-plain.json" > "$(spool_dir)/preset.file"; printf 'Words.\n' ;;
esac
exit 0
EOF2
/bin/chmod +x "$switcher"
saved_pdfutil="$INTERP_PDFUTIL_BIN"
INTERP_PDFUTIL_BIN="$switcher"; export INTERP_PDFUTIL_BIN
omc_run interp.tdoc.run
INTERP_PDFUTIL_BIN="$saved_pdfutil"; export INTERP_PDFUTIL_BIN
check "(the fake really switched the preset)" "$TEST_PRESETS/20-plain.json" "$(spool_file preset.file)"
check_absent "nothing was published" "$(spool_dir)/job.json"
check "the user is told to run again" "The transform or model changed while the document was being read. Click Go again." \
    "$(ui_value "$STATUS_TEXT")"
check "Rewrite is usable again" "1" "$(ui_enabled "$TRANSLATE_BTN")"
# Positive control: the same scan with no switch publishes.
open_tdoc_window "$scan"
INTERP_PDFUTIL_BIN="$OMCTEST_WORK/pdfutil-scan"; export INTERP_PDFUTIL_BIN
omc_run interp.tdoc.run
INTERP_PDFUTIL_BIN="$saved_pdfutil"; export INTERP_PDFUTIL_BIN
check_exists "without a switch the job is published" "$(spool_dir)/job.json"
check "with the OCR text" "Recognized words." "$(spool_file source.1.txt | /usr/bin/sed -e 's/[[:space:]]*$//' | /usr/bin/grep -v '^$')"

reset_document
omctest_end
