#!/bin/sh
# Tests/72-transform-variants.test.sh - one transform that runs on two model families.
#
# Humanize runs on the Humanizer (English and Chinese, trained to pass AI detectors) and on
# Gemma 4 (any language, keeps facts better). Each family has its own preset file, tuned to that
# model, and the two files share the transform's id and name. The Transform picker lists Humanize
# once; the Model picker offers both families; and the window's preset must always be the file
# made for the selected model's family. A mismatch would not fail loudly: the Humanizer's raw
# prompt sent to Gemma 4, or Gemma 4's chat turns at temperature 0.8 sent to the Humanizer, both
# still return text, just worse text - so the pairing is checked at the level of what is recorded.
#
# Not covered: the poller (a background worker). Its part is two calls into the library -
# preset_families for the model list and sync_preset_variant after it picks a model - and both are
# checked here directly.
. "${OMCTEST_LIB:?set OMCTEST_LIB, or run via: appletbuilder test}"
. "$OMCTEST_TESTS/lib.test.interp.sh"

PRESETS="$APP_RESOURCES/Transformers"
HUMANIZER_PRESET="$PRESETS/10-humanize.json"
GEMMA_PRESET="$PRESETS/15-humanize-gemma.json"
GRAMMAR_PRESET="$PRESETS/20-fix-grammar.json"

open_transform_window() {
    omc_control_defaults transform.window
    omc_run interp.transform.init
}

# Both families installed, and the Model picker filled the way the poller fills it: the
# transform's models, Humanizer first.
install_both() {
    make_transform_model humanizer-12B-8bit >/dev/null
    make_transform_model gemma-4-12B-it-8bit >/dev/null
}
fill_model_picker() {
    interp_tcall list_preset_model_dirs "$HUMANIZER_PRESET" > "$(spool_dir)/modelpaths"
}
model_path() { # <1-based row of the Model picker>
    /usr/bin/sed -n "${1}p" "$(spool_dir)/modelpaths"
}

pick_model() { # <1-based index>
    printf '0' > "$(spool_dir)/picker_quiet"
    omc_control "$MODEL_PICKER" "$1"
    omc_run interp.transform.model.changed
}
pick_preset() { # <1-based index>
    printf '0' > "$(spool_dir)/preset_quiet"
    omc_control "$PRESET_PICKER" "$1"
    omc_run interp.transform.preset.changed
}

section "the two Humanize files are one transform"
check "they share an id" "humanize humanize" \
    "$(/usr/bin/plutil -extract id raw -o - "$HUMANIZER_PRESET") $(/usr/bin/plutil -extract id raw -o - "$GEMMA_PRESET")"
check "and a name" "Humanize Humanize" \
    "$(/usr/bin/plutil -extract name raw -o - "$HUMANIZER_PRESET") $(/usr/bin/plutil -extract name raw -o - "$GEMMA_PRESET")"
check "its variants are both files, Humanizer first" "10-humanize.json 15-humanize-gemma.json" \
    "$(interp_tcall preset_variants "$GEMMA_PRESET" | /usr/bin/xargs -n1 /usr/bin/basename | /usr/bin/tr '\n' ' ' | /usr/bin/sed 's/ $//')"
check "it runs on both families" "humanizer gemma4it" \
    "$(interp_tcall preset_families "$GEMMA_PRESET" | /usr/bin/tr '\n' ' ' | /usr/bin/sed 's/ $//')"
check "a transform with one file is its own only variant" "20-fix-grammar.json" \
    "$(interp_tcall preset_variants "$GRAMMAR_PRESET" | /usr/bin/xargs -n1 /usr/bin/basename)"
check "the Gemma 4 variant of Humanize is found by family" "$GEMMA_PRESET" \
    "$(interp_tcall preset_variant_for_family "$HUMANIZER_PRESET" gemma4it)"
check "and a family the transform lacks finds nothing" "" \
    "$(interp_tcall preset_variant_for_family "$GRAMMAR_PRESET" humanizer)"
check "the model a transform remembers is kept per transform" "TransformModelName.humanize" \
    "$(interp_tcall transform_model_pref_key "$GEMMA_PRESET")"

section "the Transform picker lists Humanize once, and the Model picker offers both families"
reset_document
install_both
open_transform_window
check "Humanize appears once" '["Humanize","Fix grammar","Make formal","Make casual","Make concise","Simplify","Summarize"]' \
    "$(ui_prop "$PRESET_PICKER" options)"
check "its row stands for its first file" "$HUMANIZER_PRESET" "$(/usr/bin/head -1 "$(spool_dir)/presetfiles")"
check "a new window starts on the Humanizer's variant" "$HUMANIZER_PRESET" "$(spool_file preset.file)"
check "with that variant's notice" "yes" "$(contains "$(ui_value "$NOTICE_TEXT")" 'The Humanizer rewrites')"
check "Humanize offers the Humanizer and then Gemma 4" "humanizer-12B-8bit gemma-4-12B-it-8bit" \
    "$(interp_tcall list_preset_model_dirs "$HUMANIZER_PRESET" | /usr/bin/xargs -n1 /usr/bin/basename | /usr/bin/tr '\n' ' ' | /usr/bin/sed 's/ $//')"
check "Fix grammar offers Gemma 4 only" "gemma-4-12B-it-8bit" \
    "$(interp_tcall list_preset_model_dirs "$GRAMMAR_PRESET" | /usr/bin/xargs -n1 /usr/bin/basename)"
check "a model installed for either family means no chooser" "0" "$(chain_asked interp.tmodels)"

section "picking a model of the other family switches to its variant"
fill_model_picker
printf '%s' "$(model_path 1)" > "$(spool_dir)/model.dir"
"$OMC_OMC_SUPPORT_PATH/omc_dialog_control" "$OMC_ACTIONUI_WINDOW_UUID" "$TRANSLATE_BTN" omc_enable
pick_model 2
check "Gemma 4 is selected" "$(model_path 2)" "$(model_dir_of)"
check "and Humanize runs its Gemma 4 variant" "$GEMMA_PRESET" "$(spool_file preset.file)"
check "whose notice is shown" "yes" "$(contains "$(ui_value "$NOTICE_TEXT")" 'Gemma 4 rewrites')"
check "Rewrite is off until the broker restarts" "0" "$(ui_enabled "$TRANSLATE_BTN")"
check "the pick is remembered for Humanize" "gemma-4-12B-it-8bit" "$(pref TransformModelName.humanize)"
check "and as the last transform model" "gemma-4-12B-it-8bit" "$(pref TransformModelName)"
pick_model 1
check "back on the Humanizer" "$(model_path 1)" "$(model_dir_of)"
check "the Humanizer's variant follows" "$HUMANIZER_PRESET" "$(spool_file preset.file)"
check "and its notice" "yes" "$(contains "$(ui_value "$NOTICE_TEXT")" 'The Humanizer rewrites')"
check "the pick is remembered for Humanize" "humanizer-12B-8bit" "$(pref TransformModelName.humanize)"

section "Rewrite sends the job of the variant for the selected model"
omc_control "$SRC_EDITOR" "It is worth noting that the plan has 3 steps."
fake_answer langid 0 'en'
omc_run interp.transform.run
check "on the Humanizer: the raw prompt" "yes" "$(job_says '### Rewritten:')"
check "and no chat turns" "no" "$(job_says 'Do not summarize')"
pick_model 2
omc_run interp.transform.run
check "on Gemma 4: its own instructions" "yes" "$(job_says 'Do not summarize')"
check "and not the Humanizer's prompt" "no" "$(job_says '### Rewritten:')"
check "the check after the run judges by the same variant" "$GEMMA_PRESET" "$(spool_file job.preset)"

section "each transform goes back to the model last picked for it"
# Humanize is on Gemma 4 (the last pick). Over to Fix grammar, which runs on Gemma 4 too.
pick_preset 2
check "Fix grammar is the preset" "$GRAMMAR_PRESET" "$(spool_file preset.file)"
check "and keeps the current model, which it runs on" "$(model_path 2)" "$(model_dir_of)"
pick_preset 1
check "back to Humanize: its Gemma 4 variant, the last one picked" "$GEMMA_PRESET" "$(spool_file preset.file)"
check "the transform is remembered by id" "humanize" "$(pref TransformPreset)"
# Now Humanize on the Humanizer, then Fix grammar - which cannot run on the Humanizer.
pick_model 1
pick_preset 2
check "Fix grammar leaves the Humanizer selected for the poller to replace" "$(model_path 1)" "$(model_dir_of)"
# The poller replaces it with the first model Fix grammar runs on.
printf '%s' "$(model_path 2)" > "$(spool_dir)/model.dir"
pick_preset 1
check "back to Humanize: the Humanizer again" "$(model_path 1)" "$(model_dir_of)"
check "with its variant" "$HUMANIZER_PRESET" "$(spool_file preset.file)"
pick_model 2
pick_preset 1
check "picking Humanize while on its Gemma 4 variant is no switch" "$GEMMA_PRESET" "$(spool_file preset.file)"

section "a new window opens a transform on the model last picked for it"
reset_window
pref_set TransformPreset humanize
pref_set TransformModelName.humanize gemma-4-12B-it-8bit
open_transform_window
check "Humanize opens on Gemma 4" "gemma-4-12B-it-8bit" "$(/usr/bin/basename "$(model_dir_of)")"
check "with its Gemma 4 variant" "$GEMMA_PRESET" "$(spool_file preset.file)"
check "and that variant's notice" "yes" "$(contains "$(ui_value "$NOTICE_TEXT")" 'Gemma 4 rewrites')"
reset_window
pref_set TransformModelName.humanize gemma-4-12B-it-4bit
open_transform_window
check "a remembered model that is not installed leaves the pick to the poller" "" "$(model_dir_of)"
check "on the first variant" "$HUMANIZER_PRESET" "$(spool_file preset.file)"

section "when the poller picks a model of the other family, the variant follows"
reset_window
pref_set TransformModelName.humanize ""
open_transform_window
fill_model_picker
printf '%s' "$(model_path 2)" > "$(spool_dir)/model.dir"
interp_tcall sync_preset_variant "$(spool_dir)"
check "Gemma 4 picked: the Gemma 4 variant" "$GEMMA_PRESET" "$(spool_file preset.file)"
check "with its notice" "yes" "$(contains "$(ui_value "$NOTICE_TEXT")" 'Gemma 4 rewrites')"
interp_tcall sync_preset_variant "$(spool_dir)"
check "a second look changes nothing" "$GEMMA_PRESET" "$(spool_file preset.file)"
printf '%s' "$GRAMMAR_PRESET" > "$(spool_dir)/preset.file"
printf '%s' "$(model_path 1)" > "$(spool_dir)/model.dir"
interp_tcall sync_preset_variant "$(spool_dir)"
check "a transform with no variant for the model's family is left alone" "$GRAMMAR_PRESET" "$(spool_file preset.file)"

section "the Humanizer's refusal of another language points to Gemma 4"
reset_document
install_both
open_transform_window
omc_control "$SRC_EDITOR" "Dzien dobry, to jest dlugi tekst po polsku."
fake_answer langid 0 'pl'
omc_run interp.transform.run
check_absent "nothing was published" "$(spool_dir)/job.json"
check "the status line names the models" \
    "Humanizer works on English and Chinese text, and this looks like Polish. Choose a Gemma 4 model under Model to rewrite it." \
    "$(ui_value "$STATUS_TEXT")"
fill_model_picker
printf '%s' "$(model_path 1)" > "$(spool_dir)/model.dir"
pick_model 2
omc_run interp.transform.run
check_exists "on Gemma 4 the same text goes through" "$(spool_dir)/job.json"

section "the document window lists Humanize once and follows the Model picker too"
reset_document
install_both
doc="$(make_text_file report.txt 'It is worth noting that the report is long.')"
pb_set "${INTERP_PB_PREFIX}INTERP_TDOC_INPUT_PATH" "$doc"
omc_control_defaults transform.doc.window
omc_run interp.tdoc.init
check "Humanize appears once" '["Humanize","Fix grammar","Make formal","Make casual","Make concise","Simplify","Summarize"]' \
    "$(ui_prop "$PRESET_PICKER" options)"
fill_model_picker
printf '%s' "$(model_path 1)" > "$(spool_dir)/model.dir"
pick_model 2
check "Gemma 4 runs the Gemma 4 variant" "$GEMMA_PRESET" "$(spool_file preset.file)"
check "and the output keeps the transform's name" "$OMCTEST_WORK/report-humanized.txt" "$(output_path)"

reset_document
omctest_end
