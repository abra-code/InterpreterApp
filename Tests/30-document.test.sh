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

section "the default output is named for its language, sits next to the original, and never overwrites"
doc="$(make_text_file report.txt 'text')"
open_doc_window "$doc"
# The name carries the language the file is IN, so translating one document into several
# languages leaves files that can be told apart instead of one that each run supersedes.
check "the default output was computed" "$OMCTEST_WORK/report-es.txt" \
    "$(output_path)"
check "and shown in the window"         "$OMCTEST_WORK/report-es.txt" \
    "$(ui_value "$OUTPUT_PATH_TEXT")"
check "the suffix is the To picker's language" "es" \
    "$(interp_call resolve_lang_code "$(spool_dir)" "$(ui_value "$TO_PICKER")")"
# Nothing is written yet, so there is nothing to preview or reveal.
check "the output preview starts empty" "" "$(ui_value "$QL_OUTPUT")"
check "and Reveal starts off"           "0" "$(ui_enabled "$REVEAL_OUTPUT_BTN")"

# With that name already taken, the next one has to be free rather than clobber it.
printf 'an earlier translation\n' > "$OMCTEST_WORK/report-es.txt"
open_doc_window "$doc"
check "an existing translation is not overwritten" "$OMCTEST_WORK/report-es-1.txt" \
    "$(output_path)"
printf 'and another\n' > "$OMCTEST_WORK/report-es-1.txt"
open_doc_window "$doc"
check "and it keeps counting"                      "$OMCTEST_WORK/report-es-2.txt" \
    "$(output_path)"
check "the earlier files are still there"          "an earlier translation" \
    "$(/bin/cat "$OMCTEST_WORK/report-es.txt")"
/bin/rm -f "$OMCTEST_WORK/report-es.txt" "$OMCTEST_WORK/report-es-1.txt"

section "unique_output_path handles a name with no extension, and one with several"
check "no extension"    "$OMCTEST_WORK/README-pl.txt" \
    "$(interp_call unique_output_path "$OMCTEST_WORK/README" pl)"
# Only the LAST extension is dropped, so "notes.v2.txt" keeps its version.
check "several dots"    "$OMCTEST_WORK/notes.v2-pl.txt" \
    "$(interp_call unique_output_path "$OMCTEST_WORK/notes.v2.txt" pl)"
# A regional code is a filename like any other, and stays intact.
check "a regional code"  "$OMCTEST_WORK/notes-zh-Hans.txt" \
    "$(interp_call unique_output_path "$OMCTEST_WORK/notes.txt" zh-Hans)"

section "switching the To language renames the output and drops the stale preview"
# The bug this covers: with one name for every language, a second run into a different language
# overwrote the first file and the right-hand pane went on showing the earlier translation.
doc="$(make_text_file memoir.txt 'text')"
open_doc_window "$doc"
# The first translation into Spanish, as the poller would have left it.
printf 'la traduccion\n' > "$OMCTEST_WORK/memoir-es.txt"
interp_call refresh_doc_output "$(spool_dir)" es
check "the Spanish output is previewed" "$OMCTEST_WORK/memoir-es.txt" "$(ui_value "$QL_OUTPUT")"
check "and Reveal is on"                "1" "$(ui_enabled "$REVEAL_OUTPUT_BTN")"

# populate leaves a quiet window in which the change handler ignores its picker, because the
# programmatic restore fires it too; a real user pick lands after it has passed.
printf '0' > "$(spool_dir)/lang_quiet"
omc_control "$TO_PICKER" "$(interp_call lang_code_index "$(spool_dir)" pl)"
omc_run interp.to.changed
check "the output is named for Polish now" "$OMCTEST_WORK/memoir-pl.txt" "$(output_path)"
check "and shown"                          "$OMCTEST_WORK/memoir-pl.txt" \
    "$(ui_value "$OUTPUT_PATH_TEXT")"
# There is no Polish translation yet, so the pane must not keep showing the Spanish one.
check "the Spanish preview is gone" "" "$(ui_value "$QL_OUTPUT")"
check "and Reveal went off"         "0" "$(ui_enabled "$REVEAL_OUTPUT_BTN")"
check "the To language was persisted" "pl" "$(pref ToLang)"

# Back to Spanish: the file this window already produced is reused rather than uniquified away
# from, so a re-run replaces its own output instead of piling up memoir-es-1, -2, -3.
omc_control "$TO_PICKER" "$(interp_call lang_code_index "$(spool_dir)" es)"
omc_run interp.to.changed
check "the earlier Spanish output is reused" "$OMCTEST_WORK/memoir-es.txt" "$(output_path)"
check "and comes back into the preview"      "$OMCTEST_WORK/memoir-es.txt" \
    "$(ui_value "$QL_OUTPUT")"
check "with Reveal back on"                  "1" "$(ui_enabled "$REVEAL_OUTPUT_BTN")"
/bin/rm -f "$OMCTEST_WORK/memoir-es.txt"

section "the text window is untouched by any of that"
# interp.to.changed is shared with the translator window, which has no output file at all. The
# spool is given an input document so the mode gate is the ONLY thing standing between the handler
# and an output path - otherwise this section would pass for the wrong reason, "there was nothing
# to derive a name from" being indistinguishable from "the gate held".
reset_document
/bin/mkdir -p "$(spool_dir)"
printf '%s' "$(make_text_file decoy.txt 'text')" > "$(spool_dir)/input.path"
interp_call populate_language_pickers "$(spool_dir)" >/dev/null 2>&1
printf '0' > "$(spool_dir)/lang_quiet"
omc_control "$TO_PICKER" "$(interp_call lang_code_index "$(spool_dir)" pl)"
omc_run interp.to.changed
check "the selection is still persisted" "pl" "$(pref ToLang)"
check "and no output path was invented" "" "$(output_path)"
# The positive control: the same spool in document mode does derive one.
printf 'doc' > "$(spool_dir)/mode"
omc_run interp.to.changed
check "which the document window would have" "$OMCTEST_WORK/decoy-pl.txt" "$(output_path)"

section "pointing the preview at a file it already shows still reloads it"
# QuickLook ignores a source string it already holds, so a re-run into the SAME language - which
# overwrites its own file, same path, new text - would leave the previous translation on screen.
# Clearing first is what makes the second write a change the element acts on.
reset_document
target="$OMCTEST_WORK/preview.txt"
printf 'first\n' > "$target"
interp_call set_quicklook "$QL_OUTPUT" "$target"
check "the preview was cleared first"  "" "$(ui_writes "$QL_OUTPUT" | /usr/bin/sed -n 1p)"
check "and then pointed at the file"   "$target" "$(ui_writes "$QL_OUTPUT" | /usr/bin/sed -n 2p)"
check "which is two writes, not one"   "2" "$(ui_writes "$QL_OUTPUT" | /usr/bin/grep -c '')"
ui_reset
interp_call set_quicklook "$QL_OUTPUT" ""
check "clearing it is a single write"  "1" "$(ui_writes "$QL_OUTPUT" | /usr/bin/grep -c '')"
check "of nothing"                     "" "$(ui_value "$QL_OUTPUT")"

section "delivering a finished translation writes it and shows what it wrote"
# The poller itself cannot run under test - it is an unbounded loop that would race every
# assertion - so the delivery it performs lives in a library function, and this is that function.
# Everything the user sees at the end of a translation is decided here.
reset_document
/bin/mkdir -p "$(spool_dir)"
dest="$OMCTEST_WORK/delivered-pl.txt"
/bin/rm -f "$dest"
printf 'stale from the previous run\n' > "$dest"
printf '%s' "$dest" > "$(spool_dir)/job.output.path"
printf 'the new translation\n' > "$(spool_dir)/result.txt"
check "it reports a delivery" "yes" "$(interp_is deliver_doc_result "$(spool_dir)")"
check "the file holds the new translation" "the new translation" "$(/bin/cat "$dest")"
check "the Output field names it"  "$dest" "$(ui_value "$OUTPUT_PATH_TEXT")"
check "and it is recorded"         "$dest" "$(output_path)"
check "Reveal came on"             "1" "$(ui_enabled "$REVEAL_OUTPUT_BTN")"
# The reported bug: the destination was overwritten in place, so an unforced QuickLook would go
# on showing the previous language's words. Delivery must clear the pane before re-pointing it.
check "the preview was reloaded, not merely re-set" "2" \
    "$(ui_writes "$QL_OUTPUT" | /usr/bin/grep -c '')"
check "ending on the delivered file" "$dest" "$(ui_value "$QL_OUTPUT")"

# The destination captured at dispatch wins over the current default name, which the To picker is
# free to have moved while the translation ran.
ui_reset
printf '%s' "$OMCTEST_WORK/moved-on-es.txt" > "$(spool_dir)/output.path"
printf 'again\n' > "$(spool_dir)/result.txt"
interp_call deliver_doc_result "$(spool_dir)" >/dev/null 2>&1
check "the job's own destination was used" "again" "$(/bin/cat "$dest")"
check_absent "and the newer name was left alone" "$OMCTEST_WORK/moved-on-es.txt"

# With no destination at all there is nothing to deliver: rc 2 tells the poller to try again
# later rather than mark this result delivered.
ui_reset
/bin/rm -f "$(spool_dir)/job.output.path" "$(spool_dir)/output.path"
interp_call deliver_doc_result "$(spool_dir)" >/dev/null 2>&1
check "no destination is not a delivery" "2" "$?"
check "and nothing was said about it"    "" "$(ui_value "$STATUS_TEXT")"

# A write that cannot land says so, rather than leaving reflect_ui's independent "Ready" to
# suggest a file was saved that was not.
ui_reset
unwritable="$OMCTEST_WORK/no-such-directory/out.txt"
printf '%s' "$unwritable" > "$(spool_dir)/job.output.path"
interp_call deliver_doc_result "$(spool_dir)" >/dev/null 2>&1
check "a failed write is reported as one" "1" "$?"
check "and the status line says where"    "Could not write the translation to $unwritable" \
    "$(ui_value "$STATUS_TEXT")"
check "Reveal was not turned on"          "" "$(ui_enabled "$REVEAL_OUTPUT_BTN")"

section "choosing a different output takes effect from the next Translate"
doc="$(make_text_file memo.txt 'text')"
open_doc_window "$doc"
elsewhere="$OMCTEST_WORK/Elsewhere/memo-fr.txt"
/bin/mkdir -p "$OMCTEST_WORK/Elsewhere"
# The engine hands a handler the picker's current value; here the window opened on the default To
# language, so that is what Choose... is answering for.
omc_control "$TO_PICKER" "$(interp_call lang_code_index "$(spool_dir)" es)"
omc_dialog_answer save_as "$elsewhere"
omc_run interp.doc.choose.output
check "the new path was recorded" "$elsewhere" "$(output_path)"
check "and shown"                 "$elsewhere" "$(ui_value "$OUTPUT_PATH_TEXT")"

# An empty answer is how the engine reports Cancel.
omc_dialog_answer save_as ""
omc_run interp.doc.choose.output
check "cancelling leaves it alone" "$elsewhere" "$(output_path)"

# A chosen path is remembered against the language it was chosen for, so it survives a trip
# through the To picker rather than being re-derived over the top of the user's decision.
printf '0' > "$(spool_dir)/lang_quiet"
omc_control "$TO_PICKER" "$(interp_call lang_code_index "$(spool_dir)" pl)"
omc_run interp.to.changed
check "another language derives its own name" "$OMCTEST_WORK/memo-pl.txt" "$(output_path)"
omc_control "$TO_PICKER" "$(interp_call lang_code_index "$(spool_dir)" es)"
omc_run interp.to.changed
check "and coming back restores the choice"   "$elsewhere" "$(output_path)"

# Now the same thing after a USER pick, which is where the language a choice is filed under can
# disagree with the spool: a pick made inside populate's quiet window is deliberately ignored by
# interp.to.changed, so the spool still says Spanish while the picker says Polish. Save As must
# file the choice under what the PICKER says, or the next Translate - which settles its
# destination from the memo for the language it dispatches - would never see it.
doc="$(make_text_file quiet.txt 'Some text.')"
open_doc_window "$doc"
printf '%s' "$(models_dir)/translategemma-12b-4bit" > "$(spool_dir)/model.dir"
chosen="$OMCTEST_WORK/Elsewhere/a chosen name.txt"
# Pinned rather than left to the clock: the window populate arms is two seconds and the handler
# runs about a tenth of a second later, so the pick would be swallowed anyway - but by accident of
# timing rather than as a fact of the test, and a loaded machine could turn that into a flake.
printf '%s' "$(( $(/bin/date +%s) + 3600 ))" > "$(spool_dir)/lang_quiet"
omc_control "$TO_PICKER" "$(interp_call lang_code_index "$(spool_dir)" pl)"
omc_run interp.to.changed          # swallowed: inside the quiet window
check "the spool did not follow the pick" "es" "$(spool_file to.code)"
omc_dialog_answer save_as "$chosen"
omc_run interp.doc.choose.output
check "the choice was filed under Polish" "$chosen" "$(spool_file outputs/pl)"
omc_control "$FROM_PICKER" "$(interp_call lang_code_index "$(spool_dir)" en)"
omc_run interp.doc.translate
check "and Translate honors it"           "$chosen" "$(output_path)"
check "as the job's destination"          "$chosen" "$(spool_file job.output.path)"

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
# The destination follows the language dispatched, which the picker can carry without
# interp.to.changed ever running - a programmatic set, or this very test.
check "the destination follows the To language" "$OMCTEST_WORK/source-en.txt" "$(output_path)"
check "and was captured for this job"           "$OMCTEST_WORK/source-en.txt" \
    "$(spool_file job.output.path)"

# A To change while the translation is in flight moves the default name for the NEXT run. The
# job already dispatched keeps the destination it was dispatched with, so the poller cannot be
# made to write this translation under another language's name.
printf '0' > "$(spool_dir)/lang_quiet"
omc_control "$TO_PICKER" "$(interp_call lang_code_index "$(spool_dir)" de)"
omc_run interp.to.changed
check "the next run would go to German" "$OMCTEST_WORK/source-de.txt" "$(output_path)"
check "the job in flight is unmoved"    "$OMCTEST_WORK/source-en.txt" \
    "$(spool_file job.output.path)"

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
