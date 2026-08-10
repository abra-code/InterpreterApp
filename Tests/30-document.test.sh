#!/bin/sh
# Tests/30-document.test.sh - the document-translation window.
#
# This is the window that writes FILES, so its two riskiest behaviors are the
# output path it picks (it must never overwrite a document the user already has)
# and its judgement about whether a document could be read at all. textutil's
# own exit status lies - it returns 0 for a package it cannot read while writing
# nothing - so "could not read this" is decided by the applet, and getting it
# wrong means either a bogus error on a good file or a silent translation of
# nothing.
. "${OMCTEST_LIB:?set OMCTEST_LIB, or run via: appletbuilder test}"
. "$OMCTEST_TESTS/lib.test.interp.sh"

# Open the document window on a file, the way every route into it does: through
# the private pasteboard handoff that interp.doc.init consumes.
open_doc_window() { # <input-path>
    reset_document
    make_mlx_model translategemma-12b-4bit >/dev/null
    pb_set "${INTERP_PB_PREFIX}INTERP_DOC_INPUT_PATH" "$1"
    omc_control_defaults doc.window
    omc_run interp.doc.init
}

section "the window opens on the handed-off document"
doc="$(make_text_file letter.txt 'Bonjour, comment allez-vous ?')"
open_doc_window "$doc"
check_status "init ran" 0
check "the input path was recorded" "$doc" "$(input_path)"
check "and shown"                   "$doc" "$(ui_value "$INPUT_PATH_TEXT")"
check "the original is previewed"   "$doc" "$(ui_value "$QL_INPUT")"
check "the window is in document mode" "doc" "$(spool_file mode)"
wait_for_calls interp.poll.sh 1
# The mode is what makes the shared poller write the finished translation to a
# FILE rather than into an editor pane.
check "and the poller was told so"  "doc" "$(fake_arg_at interp.poll.sh 3)"
check "the poller got this window"  "$OMC_ACTIONUI_WINDOW_UUID" "$(fake_arg_at interp.poll.sh 1)"
check "and this spool"              "$(spool_dir)" "$(fake_arg_at interp.poll.sh 2)"
check "Translate starts disabled"   "0" "$(ui_enabled "$TRANSLATE_BTN")"
check "Stop starts disabled"        "0" "$(ui_enabled "$STOP_BTN")"

section "the handoff is consumed, so a later window does not reuse it"
check "the key was cleared" "" "$(doc_handoff)"
reset_window
omc_run interp.doc.init
check "a window opened with no handoff says so" "No input document." \
    "$(ui_value "$STATUS_TEXT")"
check "and records no input path" "" "$(input_path)"

section "the default output sits next to the original and never overwrites"
doc="$(make_text_file report.txt 'text')"
open_doc_window "$doc"
check "the default output was computed" "$OMCTEST_WORK/report-translated.txt" \
    "$(output_path)"
check "and shown in the window"         "$OMCTEST_WORK/report-translated.txt" \
    "$(ui_value "$OUTPUT_PATH_TEXT")"

# With that name already taken, the next one has to be free rather than clobber it.
printf 'an earlier translation\n' > "$OMCTEST_WORK/report-translated.txt"
open_doc_window "$doc"
check "an existing translation is not overwritten" "$OMCTEST_WORK/report-translated-1.txt" \
    "$(output_path)"
printf 'and another\n' > "$OMCTEST_WORK/report-translated-1.txt"
open_doc_window "$doc"
check "and it keeps counting"                      "$OMCTEST_WORK/report-translated-2.txt" \
    "$(output_path)"
check "the earlier files are still there"          "an earlier translation" \
    "$(/bin/cat "$OMCTEST_WORK/report-translated.txt")"
/bin/rm -f "$OMCTEST_WORK/report-translated.txt" "$OMCTEST_WORK/report-translated-1.txt"

section "unique_output_path handles a name with no extension, and one with several"
check "no extension"    "$OMCTEST_WORK/README-translated.txt" \
    "$(interp_call unique_output_path "$OMCTEST_WORK/README")"
# Only the LAST extension is dropped, so "notes.v2.txt" keeps its version.
check "several dots"    "$OMCTEST_WORK/notes.v2-translated.txt" \
    "$(interp_call unique_output_path "$OMCTEST_WORK/notes.v2.txt")"

section "choosing a different output takes effect from the next Translate"
doc="$(make_text_file memo.txt 'text')"
open_doc_window "$doc"
elsewhere="$OMCTEST_WORK/Elsewhere/memo-fr.txt"
/bin/mkdir -p "$OMCTEST_WORK/Elsewhere"
omc_dialog_answer save_as "$elsewhere"
omc_run interp.doc.choose.output
check "the new path was recorded" "$elsewhere" "$(output_path)"
check "and shown"                 "$elsewhere" "$(ui_value "$OUTPUT_PATH_TEXT")"

# An empty answer is how the engine reports Cancel.
omc_dialog_answer save_as ""
omc_run interp.doc.choose.output
check "cancelling leaves it alone" "$elsewhere" "$(output_path)"

section "Reveal opens the Finder only once there is something to show"
doc="$(make_text_file shown.txt 'text')"
open_doc_window "$doc"
omc_run interp.doc.reveal
# The output file does not exist yet - the poller writes it on completion - so
# there is nothing to reveal and the Finder must not be raised.
check "nothing was revealed yet" "0" "$(fake_calls open)"
printf 'translated\n' > "$(output_path)"
omc_run interp.doc.reveal
check "and now it is" "yes" "$(fake_arg open "$(output_path)" 1)"
check "with -R, not -a" "yes" "$(fake_arg open -R 1)"

section "Translate converts the document and publishes a job"
doc="$(make_text_file source.txt 'Le chat dort sur le canape.')"
open_doc_window "$doc"
printf '%s' "$(models_dir)/translategemma-12b-4bit" > "$(spool_dir)/model.dir"
omc_control "$FROM_PICKER" "$(interp_call lang_code_index "$(spool_dir)" fr)"
omc_control "$TO_PICKER" "$(interp_call lang_code_index "$(spool_dir)" en)"
omc_trigger "$TRANSLATE_BTN"
omc_run interp.doc.translate
check_status "the handler ran" 0
check_exists "a job was published" "$(spool_dir)/job.json"
# textutil runs FOR REAL here: it is deterministic, safe, and it is what
# normalizes a UTF-16 or BOM'd document to the UTF-8 the model needs. Faking it
# would leave the one conversion path the applet depends on untested.
check "the converted text reached the job" "Le chat dort sur le canape." \
    "$(job_source_text | /usr/bin/sed -e 's/[[:space:]]*$//')"
check "with the chosen language pair" "yes" "$(job_says '"source_lang_code":"fr"')"
check "Translate went off"  "0" "$(ui_enabled "$TRANSLATE_BTN")"
check "Stop came on"        "1" "$(ui_enabled "$STOP_BTN")"
# The previous output is about to be superseded, so its Reveal affordance no
# longer points at the current translation.
check "Reveal went off"     "0" "$(ui_enabled "$REVEAL_OUTPUT_BTN")"
check "the status line says so" "Translating…" "$(ui_value "$STATUS_TEXT")"
check "the dispatch lock was released" "no" \
    "$([ -d "$(spool_dir)/dispatch.lock" ] && echo yes || echo no)"

section "a stale cancel flag does not kill the next run"
# Stop during a PREVIOUS conversion leaves convert.cancel behind. A fresh run
# clears it first, or the very next Translate would report "Cancelled" without
# the user having asked for anything.
doc="$(make_text_file again.txt 'Encore un texte.')"
open_doc_window "$doc"
printf '%s' "$(models_dir)/translategemma-12b-4bit" > "$(spool_dir)/model.dir"
/usr/bin/touch "$(spool_dir)/convert.cancel"
omc_control "$FROM_PICKER" "$(interp_call lang_code_index "$(spool_dir)" fr)"
omc_control "$TO_PICKER" "$(interp_call lang_code_index "$(spool_dir)" en)"
omc_run interp.doc.translate
check_exists "the run went through" "$(spool_dir)/job.json"
check "and the stale flag was cleared" "no" \
    "$([ -f "$(spool_dir)/convert.cancel" ] && echo yes || echo no)"

section "an empty document is refused with a modal alert, not a silent job"
doc="$(make_text_file blank.txt '
   ')"
open_doc_window "$doc"
printf '%s' "$(models_dir)/translategemma-12b-4bit" > "$(spool_dir)/model.dir"
omc_control "$FROM_PICKER" "$(interp_call lang_code_index "$(spool_dir)" fr)"
omc_control "$TO_PICKER" "$(interp_call lang_code_index "$(spool_dir)" en)"
omc_run interp.doc.translate
check_absent "nothing was published" "$(spool_dir)/job.json"
check "the status line says why" "No text to translate." "$(ui_value "$STATUS_TEXT")"
# A status-line trace alone is too easy to miss for something the user asked
# for and did not get.
check "and the user was actually told" "Nothing to translate" \
    "$(ui_alert_title)"
check "Translate is usable again" "1" "$(ui_enabled "$TRANSLATE_BTN")"
check "and Stop went off"         "0" "$(ui_enabled "$STOP_BTN")"

section "a document that cannot be read is refused, and says so"
# A .pages package is the case textutil lies about: it prints a diagnostic and
# writes nothing, while still exiting 0.
pages="$OMCTEST_WORK/Keynote.pages"
/bin/mkdir -p "$pages"
printf 'not really a pages file\n' > "$pages/index.xml"
open_doc_window "$pages"
printf '%s' "$(models_dir)/translategemma-12b-4bit" > "$(spool_dir)/model.dir"
omc_control "$FROM_PICKER" "$(interp_call lang_code_index "$(spool_dir)" fr)"
omc_control "$TO_PICKER" "$(interp_call lang_code_index "$(spool_dir)" en)"
omc_run interp.doc.translate
check_absent "nothing was published" "$(spool_dir)/job.json"
check "the status line says so" "Could not read this document." "$(ui_value "$STATUS_TEXT")"
check "and an alert names the file" "Can't read this document" "$(ui_alert_title)"
check "Translate is usable again"   "1" "$(ui_enabled "$TRANSLATE_BTN")"

section "convert_to_plain_text judges readability, not textutil's exit status"
readable="$(make_text_file plain.txt 'Just some text.')"
out="$OMCTEST_WORK/converted.txt"
check "a readable document converts" "yes" \
    "$(interp_is convert_to_plain_text "$readable" "$out")"
check "and the text came through" "Just some text." \
    "$(/bin/cat "$out" | /usr/bin/sed -e 's/[[:space:]]*$//')"
check "an unreadable package does not" "no" \
    "$(interp_is convert_to_plain_text "$pages" "$out")"
# A stale output from a previous attempt is removed first, so "no output file"
# is a detectable signal rather than a leftover.
check_absent "and left no stale output behind" "$out"

section "a PDF is routed to pdfutil, never to textutil"
# Detection is by CONTENT, not extension, so a PDF saved without a .pdf suffix
# is still routed correctly - and a real PDF handed to textutil would be
# silently misread as text and translated as garbage.
pdf_like="$(make_text_file report.dat '%PDF-1.7
1 0 obj')"
check "the signature is recognized" "yes" "$(interp_is is_pdf "$pdf_like")"
check "a plain text file is not"    "no"  "$(interp_is is_pdf "$readable")"
# PDF readers tolerate a few leading bytes, so the first kilobyte is scanned
# rather than only offset 0.
offset_pdf="$(make_text_file offset.dat '
%PDF-1.4')"
check "and neither is a header a few bytes in a problem" "yes" \
    "$(interp_is is_pdf "$offset_pdf")"

fake_answer pdfutil 0 'Extracted page text'
check "the PDF path succeeds when pdfutil does" "yes" \
    "$(interp_is convert_to_plain_text "$pdf_like" "$OMCTEST_WORK/pdf-out.txt")"
check "pdfutil was asked for text" "yes" "$(fake_arg pdfutil text 1)"
fake_answer pdfutil 1 ''
check "and fails when pdfutil cannot read it" "no" \
    "$(interp_is convert_to_plain_text "$pdf_like" "$OMCTEST_WORK/pdf-out.txt")"
check_absent "leaving no half-written output" "$OMCTEST_WORK/pdf-out.txt"

section "Translate refuses a language pair it cannot resolve"
doc="$(make_text_file pair.txt 'Some text.')"
open_doc_window "$doc"
omc_control "$FROM_PICKER" "99999"
omc_control "$TO_PICKER" "1"
omc_run interp.doc.translate
check_absent "nothing was published" "$(spool_dir)/job.json"
check "the status line says what to do" "Please choose valid From and To languages." \
    "$(ui_value "$STATUS_TEXT")"
check "Translate is usable again" "1" "$(ui_enabled "$TRANSLATE_BTN")"
check "and Stop went off"         "0" "$(ui_enabled "$STOP_BTN")"

section "Translate refuses when the input document has gone away"
doc="$(make_text_file vanishing.txt 'Some text.')"
open_doc_window "$doc"
/bin/rm -f "$doc"
omc_control "$FROM_PICKER" "$(interp_call lang_code_index "$(spool_dir)" fr)"
omc_control "$TO_PICKER" "$(interp_call lang_code_index "$(spool_dir)" en)"
omc_run interp.doc.translate
check_absent "nothing was published" "$(spool_dir)/job.json"
check "the status line says so" "No input document." "$(ui_value "$STATUS_TEXT")"

section "a second dispatch cannot interleave with one in flight"
doc="$(make_text_file locked.txt 'Some text.')"
open_doc_window "$doc"
printf '%s' "$(models_dir)/translategemma-12b-4bit" > "$(spool_dir)/model.dir"
omc_control "$FROM_PICKER" "$(interp_call lang_code_index "$(spool_dir)" fr)"
omc_control "$TO_PICKER" "$(interp_call lang_code_index "$(spool_dir)" en)"
/bin/mkdir "$(spool_dir)/dispatch.lock"
omc_run interp.doc.translate
check_absent "the second dispatch published nothing" "$(spool_dir)/job.json"
/bin/rmdir "$(spool_dir)/dispatch.lock"
omc_run interp.doc.translate
check_exists "and goes through once the lock is free" "$(spool_dir)/job.json"

section "closing the document window sweeps its spool"
doc="$(make_text_file closing.txt 'text')"
open_doc_window "$doc"
check_exists "the spool is there to begin with" "$(spool_dir)"
omc_run interp.doc.cancel
# Removing the spool is also how the broker and the poller are told to exit:
# both loop on its existence.
check_absent "and gone afterwards" "$(spool_dir)"

section "cumulative: no handler wrote to a view id the window does not declare"
check "no undeclared ids" "" "$(ui_unknown_writes)"
check "no bare value write clobbered a table" "" "$(ui_suspect_writes)"
check "the harness detected no misuse" "" "$(ui_errors)"

omctest_end
