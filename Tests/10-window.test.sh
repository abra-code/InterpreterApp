#!/bin/sh
# Tests/10-window.test.sh - the translator (two-editor) window, and the routing
# that decides which window opens at all.
#
# The routing is the part with the most ways to be silently wrong: the same
# handoff is used by a launch drop, File > Open, and two macOS services, and it
# travels through a GLOBAL pasteboard key rather than a per-window one.
. "${OMCTEST_LIB:?set OMCTEST_LIB, or run via: appletbuilder test}"
. "$OMCTEST_TESTS/lib.test.interp.sh"

section "the window opens with its controls disabled"
reset_document
make_mlx_model "translategemma-12b-4bit" >/dev/null
omc_control_defaults interpreter.window
omc_run interp.window.init
check_status "init ran" 0
check_exists "the window got a spool directory" "$(spool_dir)"
check_exists "and a Models directory to look in" "$(models_dir)"
# Nothing can be translated until the poller reports the model ready, so the
# action controls start off and the poller turns them on.
check "Translate is disabled" "0" "$(ui_enabled "$TRANSLATE_BTN")"
check "Swap is disabled"      "0" "$(ui_enabled "$SWAP_BTN")"
check "Stop is disabled"      "0" "$(ui_enabled "$STOP_BTN")"
check "the status line says it is starting" "Starting…" "$(ui_value "$STATUS_TEXT")"

section "init launches the poller for this window and this spool"
# The poller is spawned with "&" and the handler returns immediately, so the
# recorder may not have written its record yet. Without this the three checks
# below pass or fail with machine load.
wait_for_calls interp.poll.sh 1
# The poller, not this handler, owns the model broker - which is what makes
# first-run auto-pickup and in-dialog model switching work without init knowing
# about either. All the handler is responsible for is launching it correctly.
check "the poller was launched once" "1" "$(fake_calls interp.poll.sh)"
check "for this window"  "$OMC_ACTIONUI_WINDOW_UUID" "$(fake_arg_at interp.poll.sh 1)"
check "and this spool"   "$(spool_dir)"              "$(fake_arg_at interp.poll.sh 2)"
# The text window passes no mode; the poller defaults to text. A third argument
# here would put this window into document mode, where a finished translation is
# written to a FILE instead of the right-hand editor.
check "with no mode argument" "" "$(fake_arg_at interp.poll.sh 3)"

section "with a model already installed, the chooser does not barge in"
check "no chooser was opened" "0" "$(chain_asked interp.models)"

section "with no model at all, the chooser opens over the translator"
reset_document
omc_control_defaults interpreter.window
omc_run interp.window.init
check "the model chooser was opened" "1" "$(chain_asked interp.models)"
wait_for_calls interp.poll.sh 1
check "and the poller still started, to keep the window in sync" "1" \
    "$(fake_calls interp.poll.sh)"

section "a directory under Models that holds no model does not count as one"
reset_document
make_empty_model_dir "half-downloaded-model" >/dev/null
omc_control_defaults interpreter.window
omc_run interp.window.init
check "the chooser opened anyway" "1" "$(chain_asked interp.models)"
check "and resolve_model_dir found nothing" "no" "$(interp_is resolve_model_dir)"

section "a GGUF install counts exactly as an MLX one does"
reset_document
gguf="$(make_gguf_model "hy-mt2-7b-q4")"
check "it is recognized as installed" "yes" "$(interp_is model_installed_at "$gguf")"
check "its engine is gguf"            "gguf" "$(interp_call model_engine_of "$gguf")"
check "and its .gguf file is found"   "$gguf/weights-Q4_K_M.gguf" \
    "$(interp_call gguf_file_in "$gguf")"
omc_control_defaults interpreter.window
omc_run interp.window.init
# The two engines are meant to be indistinguishable to everything above
# model_installed_at, so a gguf-only library must not trigger the first-run
# chooser.
check "so a gguf-only library is not a first run" "0" "$(chain_asked interp.models)"

section "the language pickers are filled and a selection restored"
reset_document
make_mlx_model "translategemma-12b-4bit" >/dev/null
omc_control_defaults interpreter.window
omc_run interp.window.init
# TranslateGemma ships no languages.<family>.tsv, so it gets the full list.
check "every shipped language is offered" \
    "$(/usr/bin/grep -c '' "$APP_RESOURCES/languages.tsv")" \
    "$(langcodes | /usr/bin/grep -c '')"
check "the unfiltered list is recorded too" \
    "$(langcodes | /usr/bin/grep -c '')" "$(langcodes_all | /usr/bin/grep -c '')"
# At init time the spool has no model.dir yet - the POLLER writes it once it has
# discovered and loaded a model - so the family is "generic" and the pickers
# offer everything. That is the right answer for the moment it is asked, and the
# recorded family is what lets the poller re-populate when the real model turns
# out to belong to a family that filters the list.
check "the family populated for is recorded" "generic" "$(langfamily)"
printf '%s' "$(models_dir)/translategemma-12b-4bit" > "$(spool_dir)/model.dir"
interp_call populate_language_pickers "$(spool_dir)" >/dev/null 2>&1
check "and re-populating with a model records its family" "translategemma" "$(langfamily)"
# Options are sorted by DISPLAY NAME, and the parallel langcodes file has to be
# in the same order or every picker index resolves to the wrong language.
first_name="$(LC_ALL=C /usr/bin/sort -f "$APP_RESOURCES/languages.tsv" | /usr/bin/sed -n '1p' | /usr/bin/cut -f1)"
first_code="$(LC_ALL=C /usr/bin/sort -f "$APP_RESOURCES/languages.tsv" | /usr/bin/sed -n '1p' | /usr/bin/cut -f2)"
check "the options start with the alphabetically first name" "yes" \
    "$(contains "$(ui_prop "$FROM_PICKER" options)" "[\"$first_name\"")"
check "and langcodes line 1 is that language's code" "$first_code" \
    "$(langcodes | /usr/bin/sed -n 1p)"
check "row 1 resolves back to it" "$first_code" "$(interp_call resolve_lang_code "$(spool_dir)" 1)"
# With nothing saved the defaults are English -> Spanish, chosen by CODE.
check "From defaults to English" "en" \
    "$(interp_call resolve_lang_code "$(spool_dir)" "$(ui_value "$FROM_PICKER")")"
check "To defaults to Spanish"   "es" \
    "$(interp_call resolve_lang_code "$(spool_dir)" "$(ui_value "$TO_PICKER")")"

section "a saved language is restored by code, not by position"
reset_window
pref_set FromLang de
pref_set ToLang fr
omc_run interp.window.init
check "From came back as German" "de" \
    "$(interp_call resolve_lang_code "$(spool_dir)" "$(ui_value "$FROM_PICKER")")"
check "To came back as French"   "fr" \
    "$(interp_call resolve_lang_code "$(spool_dir)" "$(ui_value "$TO_PICKER")")"

section "changing a picker persists the language code"
reset_document
make_mlx_model "translategemma-12b-4bit" >/dev/null
omc_control_defaults interpreter.window
omc_run interp.window.init
# The quiet window populate opens is two seconds wide and exists so that its own
# programmatic picker sets are not mistaken for user choices. A real change
# lands outside it, so it is waited out rather than worked around - otherwise
# this section would assert about the suppression path while claiming to be
# about the persistence one.
check "the quiet window closes on its own" "yes" \
    "$(omc_wait_for '[ "$(/bin/date +%s)" -gt "$(/bin/cat '"$(spool_dir)"'/lang_quiet 2>/dev/null || echo 0)" ]' 5 \
        && echo yes || echo no)"
de_row="$(interp_call lang_code_index "$(spool_dir)" de)"
omc_fire interp.from.changed "$FROM_PICKER" "$de_row"
check "From was saved as a code" "de" "$(pref FromLang)"
it_row="$(interp_call lang_code_index "$(spool_dir)" it)"
omc_fire interp.to.changed "$TO_PICKER" "$it_row"
check "To was saved as a code"   "it" "$(pref ToLang)"

section "a programmatic picker fire inside the quiet window is not a user choice"
reset_document
make_mlx_model "translategemma-12b-4bit" >/dev/null
omc_control_defaults interpreter.window
omc_run interp.window.init
# populate_language_pickers has just written a lang_quiet stamp two seconds
# ahead, and its own picker sets fire the change handlers. A family-filter
# fallback fires them with a DIFFERENT language than the one saved, so honoring
# it here would erase the preference rather than masking it for the session.
pref_set FromLang de
pl_row="$(interp_call lang_code_index "$(spool_dir)" pl)"
omc_fire interp.from.changed "$FROM_PICKER" "$pl_row"
check "the saved preference stands" "de" "$(pref FromLang)"

section "a bogus picker value is ignored rather than persisted"
reset_document
make_mlx_model "translategemma-12b-4bit" >/dev/null
omc_control_defaults interpreter.window
omc_run interp.window.init
omc_wait_for '[ "$(/bin/date +%s)" -gt "$(/bin/cat '"$(spool_dir)"'/lang_quiet 2>/dev/null || echo 0)" ]' 5
pref_set FromLang de
# Programmatic option updates can fire an action with a transitional value.
omc_fire interp.from.changed "$FROM_PICKER" "not-a-number"
check "a non-numeric index changes nothing" "de" "$(pref FromLang)"
omc_fire interp.from.changed "$FROM_PICKER" "99999"
check "an out-of-range index changes nothing either" "de" "$(pref FromLang)"
# The positive control: the same handler DOES persist a good value, so the two
# checks above are not passing because the handler is inert.
es_row="$(interp_call lang_code_index "$(spool_dir)" es)"
omc_fire interp.from.changed "$FROM_PICKER" "$es_row"
check "but a valid index is persisted" "es" "$(pref FromLang)"

section "Swap exchanges the languages"
reset_document
make_mlx_model "translategemma-12b-4bit" >/dev/null
omc_control_defaults interpreter.window
omc_run interp.window.init
omc_wait_for '[ "$(/bin/date +%s)" -gt "$(/bin/cat '"$(spool_dir)"'/lang_quiet 2>/dev/null || echo 0)" ]' 5
from_row="$(interp_call lang_code_index "$(spool_dir)" en)"
to_row="$(interp_call lang_code_index "$(spool_dir)" ja)"
omc_control "$FROM_PICKER" "$from_row"
omc_control "$TO_PICKER" "$to_row"
omc_control "$SRC_EDITOR" ""
omc_control "$TGT_EDITOR" ""
omc_trigger "$SWAP_BTN"
omc_run interp.swap
check "the From picker took the To row" "$to_row"   "$(ui_value "$FROM_PICKER")"
check "and the To picker the From row"  "$from_row" "$(ui_value "$TO_PICKER")"
check "the swap was persisted as codes, From" "ja" "$(pref FromLang)"
check "and To"                                "en" "$(pref ToLang)"

section "Swap moves the translation up only when there is one"
# With an empty target pane there is nothing to promote, and overwriting the
# source with emptiness would throw away what the user typed.
omc_control "$SRC_EDITOR" "Hello there"
omc_control "$TGT_EDITOR" ""
ui_reset
omc_trigger "$SWAP_BTN"
omc_run interp.swap
# Asserted as "the handler never wrote to it", not "it reads empty". After
# ui_reset those are the same string - a control never touched and a control
# written with emptiness both read back as "" - so the value form of this check
# cannot see the bug it names, which is the source pane being clobbered with an
# empty translation.
check "the source pane was never written to" "0" \
    "$(ui_calls "	$SRC_EDITOR	")"

omc_control "$SRC_EDITOR" "Hello there"
omc_control "$TGT_EDITOR" "Hallo zusammen"
omc_trigger "$SWAP_BTN"
omc_run interp.swap
check "the translation became the new source" "Hallo zusammen" "$(ui_value "$SRC_EDITOR")"
check "and the original moved down"           "Hello there"    "$(ui_value "$TGT_EDITOR")"

section "Translate publishes a job the broker can pick up"
reset_document
make_mlx_model "translategemma-12b-4bit" >/dev/null
omc_control_defaults interpreter.window
omc_run interp.window.init
printf '%s' "$(models_dir)/translategemma-12b-4bit" > "$(spool_dir)/model.dir"
en_row="$(interp_call lang_code_index "$(spool_dir)" en)"
de_row="$(interp_call lang_code_index "$(spool_dir)" de)"
omc_control "$FROM_PICKER" "$en_row"
omc_control "$TO_PICKER" "$de_row"
omc_control "$SRC_EDITOR" "The quick brown fox."
omc_trigger "$TRANSLATE_BTN"
omc_run interp.translate
check_status "the handler ran" 0
check_exists "a job was published" "$(spool_dir)/job.json"
check "the epoch started at 1" "1" "$(job_field epoch)"
# The source text goes to a per-epoch FILE and the JSON references it, so the
# JSON itself only ever carries fixed, safe values - text with a quote or a
# newline in it cannot break the job.
check "the text went to a per-epoch file" "The quick brown fox." "$(job_source_text)"
check "TranslateGemma gets structured chat content" "yes" \
    "$(job_says '"source_lang_code":"en"')"
check "with the target code too" "yes" "$(job_says '"target_lang_code":"de"')"
check "the dispatch was timestamped" "yes" \
    "$([ -s "$(spool_dir)/translate.start" ] && echo yes || echo no)"
# The UI transition the poller would otherwise be the first to make.
check "Translate went off"    "0" "$(ui_enabled "$TRANSLATE_BTN")"
check "Swap went off"         "0" "$(ui_enabled "$SWAP_BTN")"
check "Stop came on"          "1" "$(ui_enabled "$STOP_BTN")"
check "the status line says so" "Translating…" "$(ui_value "$STATUS_TEXT")"
check "the character count was shown" "20 characters" "$(ui_value "$CHAR_TEXT")"
check "and the previous translation was cleared" "" "$(ui_value "$TGT_EDITOR")"
check "the dispatch lock was released" "no" \
    "$([ -d "$(spool_dir)/dispatch.lock" ] && echo yes || echo no)"

section "a second Translate bumps the epoch and gets its own source file"
omc_control "$SRC_EDITOR" "A different sentence."
omc_trigger "$TRANSLATE_BTN"
omc_run interp.translate
check "the epoch advanced" "2" "$(job_field epoch)"
check "the new job points at the new text" "A different sentence." "$(job_source_text)"
# The first job's file is still there and still holds the first text: pairing
# one job's text with another job's metadata is exactly what the per-epoch file
# exists to prevent.
check "and the previous epoch's text is untouched" "The quick brown fox." \
    "$(spool_file source.1.txt)"

section "Translate refuses an empty source and a bad language pair"
reset_document
make_mlx_model "translategemma-12b-4bit" >/dev/null
omc_control_defaults interpreter.window
omc_run interp.window.init
omc_control "$SRC_EDITOR" ""
omc_run interp.translate
check_absent "nothing was published for an empty source" "$(spool_dir)/job.json"

omc_control "$SRC_EDITOR" "Some text"
omc_control "$FROM_PICKER" "99999"
omc_control "$TO_PICKER" "1"
omc_run interp.translate
check_absent "nor for an index that resolves to no language" "$(spool_dir)/job.json"
check "the status line says what to do about it" \
    "Please choose valid From and To languages." "$(ui_value "$STATUS_TEXT")"
# The UI has to come back, or the window is left with a dead Translate button.
check "Translate is usable again" "1" "$(ui_enabled "$TRANSLATE_BTN")"
check "Swap is usable again"      "1" "$(ui_enabled "$SWAP_BTN")"
check "and Stop went off"         "0" "$(ui_enabled "$STOP_BTN")"

section "a second dispatch cannot interleave with one in flight"
reset_document
make_mlx_model "translategemma-12b-4bit" >/dev/null
omc_control_defaults interpreter.window
omc_run interp.window.init
printf '%s' "$(models_dir)/translategemma-12b-4bit" > "$(spool_dir)/model.dir"
omc_control "$FROM_PICKER" "$(interp_call lang_code_index "$(spool_dir)" en)"
omc_control "$TO_PICKER" "$(interp_call lang_code_index "$(spool_dir)" de)"
omc_control "$SRC_EDITOR" "Held by the lock"
# The Translate button and its Cmd+Return shortcut are two trigger paths and
# disabling the button is async, so an atomic mkdir lock serializes dispatch.
# Holding it by hand is what a dispatch already in flight looks like.
/bin/mkdir "$(spool_dir)/dispatch.lock"
omc_run interp.translate
check_absent "the second dispatch published nothing" "$(spool_dir)/job.json"
/bin/rmdir "$(spool_dir)/dispatch.lock"
omc_run interp.translate
check_exists "and goes through once the lock is free" "$(spool_dir)/job.json"

section "Stop raises the flags the broker and the OCR loop watch"
reset_document
make_mlx_model "translategemma-12b-4bit" >/dev/null
omc_control_defaults interpreter.window
omc_run interp.window.init
omc_run interp.stop
check_exists "the broker's stop flag"          "$(spool_dir)/stop"
# The same button also cancels a document conversion that is inside the
# page-by-page OCR fallback. The flag is written FIRST so the waiting handler
# reports "Cancelled" rather than an OCR failure.
check_exists "and the conversion's cancel flag" "$(spool_dir)/convert.cancel"
check "the status line acknowledges it" "Stopping…" "$(ui_value "$STATUS_TEXT")"

section "Stop only signals a pdfutil child, never someone else's process"
reset_document
make_mlx_model "translategemma-12b-4bit" >/dev/null
omc_control_defaults interpreter.window
omc_run interp.window.init
# A real process this test owns, standing in for a pid that has been recycled
# since it was recorded. It is not pdfutil, so it must survive.
/bin/sleep 30 &
bystander=$!
printf '%s' "$bystander" > "$(spool_dir)/ocr.pid"
omc_run interp.stop
check "the unrelated process was not killed" "yes" \
    "$(/bin/kill -0 "$bystander" 2>/dev/null && echo yes || echo no)"
/bin/kill -TERM "$bystander" 2>/dev/null
wait "$bystander" 2>/dev/null

section "closing the window sweeps its spool"
reset_document
make_mlx_model "translategemma-12b-4bit" >/dev/null
omc_control_defaults interpreter.window
omc_run interp.window.init
check_exists "the spool is there to begin with" "$(spool_dir)"
omc_run interp.window.cancel
# Removing the spool is also how the broker and the poller are told to exit:
# both loop on its existence.
check_absent "and gone afterwards" "$(spool_dir)"

section "routing: a bare launch opens the translator"
reset_document
omc_object ""
omc_run Interpreter.main
check "the text window was opened" "1" "$(chain_asked interp.new)"
check "and no document window"     "0" "$(chain_asked interp.doc)"
check "nothing was handed off"     ""  "$(doc_handoff)"

section "routing: a dropped document opens the document window"
reset_document
doc="$(make_text_file dropped.txt 'Bonjour tout le monde')"
omc_object "$doc"
omc_run Interpreter.main
check "the document window was opened" "1" "$(chain_asked interp.doc)"
check "and not the text window"        "0" "$(chain_asked interp.new)"
check "the path was handed off"        "$doc" "$(doc_handoff)"

section "routing: only the first of several dropped documents is used"
reset_document
first="$(make_text_file first.txt 'one')"
second="$(make_text_file second.txt 'two')"
# The engine hands multiple objects over newline-separated. Interpreter
# translates one document at a time.
omc_object "$first
$second"
omc_run Interpreter.main
check "the first path was handed off" "$first" "$(doc_handoff)"

section "routing: a dropped FOLDER opens the translator instead"
reset_document
folder="$OMCTEST_WORK/a-folder"
/bin/mkdir -p "$folder"
omc_object "$folder"
omc_run Interpreter.main
check "the text window was opened" "1" "$(chain_asked interp.new)"
check "and nothing was handed off" "" "$(doc_handoff)"

section "routing: File > Open"
reset_document
doc="$(make_text_file opened.txt 'text')"
omc_dialog_answer choose_file "$doc"
omc_run interp.open
check "the document window was opened" "1" "$(chain_asked interp.doc)"
check "with the chosen path"           "$doc" "$(doc_handoff)"

reset_document
# An empty answer is how the engine reports Cancel: the whole OMC_DLG_ family is
# unset rather than exported empty.
omc_dialog_answer choose_file ""
omc_run interp.open
check "cancelling opens nothing" "0" "$(chain_asked interp.doc)"
check "and hands nothing off"    ""  "$(doc_handoff)"

section "routing: the file service"
reset_document
doc="$(make_text_file service.txt 'text')"
omc_object "$doc"
omc_run interp.service.file
check "the document window was opened" "1" "$(chain_asked interp.doc)"
check "with the path"                  "$doc" "$(doc_handoff)"

reset_document
omc_object "$OMCTEST_WORK/a-folder"
omc_run interp.service.file
check "a folder-only selection is ignored" "0" "$(chain_asked interp.doc)"

section "routing: the selected-text service"
reset_document
# The selection travels through a TEMP FILE rather than the pasteboard value,
# because environment variables are size-limited and a large selection would be
# truncated or rejected outright.
omctest_setvar OMC_OBJ_TEXT "Il pleut sur la ville"
omc_run interp.service.text
check "the text window was opened" "1" "$(chain_asked interp.new)"
handoff="$(service_handoff)"
check "a handoff file was left"   "yes" "$([ -n "$handoff" ] && [ -f "$handoff" ] && echo yes || echo no)"
check "holding the selection"     "Il pleut sur la ville" "$(/bin/cat "$handoff" 2>/dev/null)"

section "the translator loads that selection once, then forgets it"
make_mlx_model "translategemma-12b-4bit" >/dev/null
omc_control_defaults interpreter.window
omc_run interp.window.init
check "the selection is in the source editor" "Il pleut sur la ville" \
    "$(ui_value "$SRC_EDITOR")"
# Consumed first and the file removed, so a later File > New opens empty rather
# than re-injecting a selection from an hour ago.
check "the handoff key was consumed" "" "$(service_handoff)"
check_absent "and the temp file removed" "$handoff"

reset_window
ui_reset
omc_run interp.window.init
check "a fresh window opens empty" "" "$(ui_value "$SRC_EDITOR")"

section "an empty selection just opens an empty translator"
reset_document
omctest_setvar OMC_OBJ_TEXT ""
omc_run interp.service.text
check "the window still opened" "1" "$(chain_asked interp.new)"
check "with no handoff"         ""  "$(service_handoff)"

section "cumulative: no handler wrote to a view id the window does not declare"
check "no undeclared ids" "" "$(ui_unknown_writes)"
check "no bare value write clobbered a table" "" "$(ui_suspect_writes)"
check "the harness detected no misuse" "" "$(ui_errors)"

omctest_end
