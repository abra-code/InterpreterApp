#!/bin/sh
# Tests/50-transform.test.sh - the Text Transform window, its presets, its model library, and
# the transform kind of the model chooser.
#
# Two things here can do real damage if they go wrong quietly. A preset is turned into the job
# the model sees, and a prompt that loses a newline or a quote still "works" - it just rewrites
# worse, with nothing to notice. And the chooser now serves two libraries from one set of
# handlers: a kind resolved wrongly would list, download into, or DELETE from the other library.
# Both get checked at the level of what is actually written.
#
# Not covered, as in the rest of the suite: the poller's transform mode and the download worker
# (both background workers replaced by recorders), and what the model does with a job.
. "${OMCTEST_LIB:?set OMCTEST_LIB, or run via: appletbuilder test}"
. "$OMCTEST_TESTS/lib.test.interp.sh"

SHIPPED_PRESET="$APP_RESOURCES/Transformers/10-humanize.json"

# A second preset and a catalog that offers its family, so switching presets can be exercised.
# The shipped Humanize preset is copied in unchanged; the second one carries the chat-template
# option a Qwen3 model needs, and a bogus top_k that must never reach the server's argv.
TEST_PRESETS="$OMCTEST_WORK/presets"
/bin/mkdir -p "$TEST_PRESETS"
/bin/cp "$SHIPPED_PRESET" "$TEST_PRESETS/10-humanize.json"
cat > "$TEST_PRESETS/20-small.json" <<'EOF'
{
  "id": "humanize-small",
  "name": "Humanize (small)",
  "family": "gohumanize",
  "button": "Rewrite fast",
  "notice": "Small and fast.",
  "server": { "ctx_size": 4096, "top_k": "0 --evil", "chat_template_kwargs": "{\"enable_thinking\":false}" },
  "sampling": { "temperature": 0.9, "top_p": 0.9, "max_new_tokens": 1024 },
  "job": { "output": "stitch", "budget_tokens": 800,
           "messages": [ { "role": "system", "content": "Rewrite it." }, { "role": "user", "content": "{{chunk}}" } ] }
}
EOF
TEST_CATALOG="$OMCTEST_WORK/transform.catalog.tsv"
/bin/cp "$APP_RESOURCES/models.transform.catalog.tsv" "$TEST_CATALOG"
printf 'gohumanize\tgohumanize\tgohumanize-4B-8bit\t4\t8\tgguf\tgohumanize-open-humanizer/gguf/gohumanize-open-humanizer-Q8_0.gguf\n' >> "$TEST_CATALOG"

use_test_presets() {
    INTERP_PRESETS_DIR="$TEST_PRESETS"; INTERP_TRANSFORM_CATALOG_TSV="$TEST_CATALOG"
    export INTERP_PRESETS_DIR INTERP_TRANSFORM_CATALOG_TSV
}
use_shipped_presets() {
    unset INTERP_PRESETS_DIR INTERP_TRANSFORM_CATALOG_TSV
}

# The value a recorded tool received right after <flag>, as a number (plutil prints a JSON real
# as 1.000000, which is the same number the preset says).
flag_number() { # <tool> <flag>
    fake_argv "$1" | /usr/bin/awk -v f="$2" 'take { print $0 + 0; exit } $0 == f { take = 1 }'
}

open_transform_window() {
    omc_control_defaults transform.window
    omc_run interp.transform.init
}

section "every shipped preset is complete and names a family the catalog offers"
for f in "$APP_RESOURCES"/Transformers/*.json; do
    name="$(/usr/bin/basename "$f")"
    for key in id name family notice button sampling.temperature sampling.top_p job.budget_tokens; do
        check "$name has $key" "yes" \
            "$([ -n "$(/usr/bin/plutil -extract "$key" raw -o - "$f" 2>/dev/null)" ] && echo yes || echo no)"
    done
    fam="$(/usr/bin/plutil -extract family raw -o - "$f")"
    check "$name's family is in the transform catalog" "yes" \
        "$(/usr/bin/awk -F'\t' -v f="$fam" '$1==f { found=1 } END { print (found ? "yes" : "no") }' \
            "$APP_RESOURCES/models.transform.catalog.tsv")"
done

section "the Humanize prompt is the model card's, byte for byte"
# The model card publishes a fingerprint: the first 16 hex digits of SHA-256 over the prompt built
# for the draft "X". A changed instruction, separator or blank line changes it. plutil prints the
# string followed by one newline of its own, which is removed before hashing.
fp="$(/usr/bin/plutil -extract job.prompt raw -o - "$SHIPPED_PRESET" \
      | /usr/bin/perl -0777 -pe 's/\n\z//; s/\{\{chunk\}\}/X/' | /usr/bin/shasum -a 256 | /usr/bin/cut -c1-16)"
check "the fingerprint matches the card" "cc51d66b4c593fbe" "$fp"

section "a transformer is found by its catalog name, and only in its own library"
reset_document
use_shipped_presets
q8="$(make_transform_model humanizer-12B-8bit)"
make_transform_model humanizer-12B-4bit >/dev/null
make_transform_model not-in-the-catalog >/dev/null
make_mlx_model translategemma-12b-4bit >/dev/null
listed="$(interp_tcall list_transform_dirs humanizer)"
check "both installed Humanizer variants are listed" "2" "$(printf '%s\n' "$listed" | /usr/bin/grep -c '')"
check "best first, in catalog order" "yes" \
    "$(contains "$(printf '%s\n' "$listed" | /usr/bin/sed -n 1p)" humanizer-12B-8bit)"
check "a dir the catalog does not name is not offered" "0" \
    "$(printf '%s\n' "$listed" | /usr/bin/grep -c 'not-in-the-catalog')"
check "an unknown family lists nothing" "" "$(interp_tcall list_transform_dirs nosuchfamily)"
check "its family comes from the catalog" "humanizer" "$(interp_tcall transform_family_of "$q8")"
check "and so does its label" "Humanizer 12B (8-bit)" "$(interp_tcall transform_display_label "$q8")"
# The two libraries must never see each other: a transformer offered as a translator would be fed
# a translation job, and the reverse.
check "the translator's list does not include transformers" "0" \
    "$(interp_call list_model_dirs | /usr/bin/grep -c 'humanizer')"
check "and still lists its own model (positive control)" "1" \
    "$(interp_call list_model_dirs | /usr/bin/grep -c 'translategemma')"

section "the window opens on the saved preset with its notice and button"
reset_document
use_test_presets
make_transform_model humanizer-12B-8bit >/dev/null
pref_set TransformPreset humanize-small
open_transform_window
check_status "init ran" 0
check "the picker lists both presets" '["Humanize","Humanize (small)"]' "$(ui_prop "$PRESET_PICKER" options)"
check "the saved preset is selected" "2" "$(ui_value "$PRESET_PICKER")"
check "the spool records it for the poller" "$TEST_PRESETS/20-small.json" "$(spool_file preset.file)"
check "its notice is shown" "Small and fast." "$(ui_value "$NOTICE_TEXT")"
check "and the button takes its title" "Rewrite fast" "$(ui_prop "$TRANSLATE_BTN" title)"
check "Run is off until the poller reports ready" "0" "$(ui_enabled "$TRANSLATE_BTN")"
wait_for_calls interp.poll.sh 1
check "the poller runs in transform mode" "transform" "$(fake_arg_at interp.poll.sh 3)"
check "for this spool" "$(spool_dir)" "$(fake_arg_at interp.poll.sh 2)"
# Nothing of the small preset's family is installed, so the transform chooser opens - and not the
# translation one.
check "the transform chooser was opened" "1" "$(chain_asked interp.tmodels)"
check "the translation chooser was not" "0" "$(chain_asked interp.models)"

section "an unknown saved preset falls back to the first one"
reset_document
use_test_presets
make_transform_model humanizer-12B-8bit >/dev/null
pref_set TransformPreset no-such-preset
open_transform_window
check "the first preset is selected" "1" "$(ui_value "$PRESET_PICKER")"
check "and recorded" "$TEST_PRESETS/10-humanize.json" "$(spool_file preset.file)"
check "with a model of its family installed, no chooser opens" "0" "$(chain_asked interp.tmodels)"

section "switching presets records the new one, and the window's own echo is ignored"
reset_window
use_test_presets
open_transform_window
# Inside the quiet window populate_preset_picker opened, a picker event is its own echo.
omc_control "$PRESET_PICKER" 2
omc_run interp.transform.preset.changed
check "an echo inside the quiet window changes nothing" "$TEST_PRESETS/10-humanize.json" "$(spool_file preset.file)"
printf '0' > "$(spool_dir)/preset_quiet"
# The poller has the window ready: Rewrite is on.
"$OMC_OMC_SUPPORT_PATH/omc_dialog_control" "$OMC_ACTIONUI_WINDOW_UUID" "$TRANSLATE_BTN" omc_enable
check "(Rewrite is on before the switch)" "1" "$(ui_enabled "$TRANSLATE_BTN")"
omc_control "$PRESET_PICKER" 2
omc_run interp.transform.preset.changed
check "a real pick is recorded" "$TEST_PRESETS/20-small.json" "$(spool_file preset.file)"
# Until the poller respawns the broker with the new preset, a job would reach the old one and be
# killed with it - so Rewrite goes off at once and the poller turns it back on.
check "Rewrite goes off until the new broker is ready" "0" "$(ui_enabled "$TRANSLATE_BTN")"
check "and remembered by id" "humanize-small" "$(pref TransformPreset)"
check "the notice follows" "Small and fast." "$(ui_value "$NOTICE_TEXT")"
check "the check line of the previous output is cleared" "" "$(ui_value "$CHECK_TEXT")"
omc_control "$PRESET_PICKER" 7
omc_run interp.transform.preset.changed
check "an index past the list is ignored" "$TEST_PRESETS/20-small.json" "$(spool_file preset.file)"

section "Rewrite publishes the preset's job with the text intact"
reset_document
use_shipped_presets
make_transform_model humanizer-12B-8bit >/dev/null
open_transform_window
text='Line one with "quotes" and a back\slash.

Second paragraph: 38% of 14 databases, zuzanna - 中文.'
omc_control "$SRC_EDITOR" "$text"
omc_run interp.transform.run
check_status "run exited cleanly" 0
check_exists "a job was published" "$(spool_dir)/job.json"
check "it is epoch 1" "1" "$(/usr/bin/plutil -extract epoch raw -o - "$(spool_dir)/job.json")"
check "it points at the per-epoch source" "source.1.txt" "$(/usr/bin/plutil -extract text_file raw -o - "$(spool_dir)/job.json")"
check "the source text is byte-identical" "$text" "$(spool_file source.1.txt)"
check "the prompt is the preset's, unchanged" \
    "$(/usr/bin/plutil -extract job.prompt raw -o - "$SHIPPED_PRESET")" \
    "$(/usr/bin/plutil -extract prompt raw -o - "$(spool_dir)/job.json")"
check "start-of-text token stays on" "true" "$(/usr/bin/plutil -extract add_special_tokens raw -o - "$(spool_dir)/job.json")"
check "the chunk budget comes from the preset" "400" "$(/usr/bin/plutil -extract budget_tokens raw -o - "$(spool_dir)/job.json")"
check "Rewrite went off" "0" "$(ui_enabled "$TRANSLATE_BTN")"
check "Stop came on" "1" "$(ui_enabled "$STOP_BTN")"
check "the status says so" "Rewriting..." "$(ui_value "$STATUS_TEXT")"
check "the timing stamp was written" "yes" "$([ -s "$(spool_dir)/translate.start" ] && echo yes || echo no)"
check_absent "the dispatch lock was released" "$(spool_dir)/dispatch.lock"
omc_control "$SRC_EDITOR" "again"
omc_run interp.transform.run
check "a second run is epoch 2" "2" "$(/usr/bin/plutil -extract epoch raw -o - "$(spool_dir)/job.json")"
check "with its own source file" "again" "$(spool_file source.2.txt)"

section "Rewrite with nothing to rewrite, or no preset, publishes nothing"
reset_document
use_shipped_presets
open_transform_window
omc_control "$SRC_EDITOR" ""
omc_run interp.transform.run
check_absent "empty text publishes no job" "$(spool_dir)/job.json"
/bin/rm -f "$(spool_dir)/preset.file"
omc_control "$SRC_EDITOR" "some text"
omc_run interp.transform.run
check_absent "no preset publishes no job" "$(spool_dir)/job.json"
check "and says why" "Choose a transform first." "$(ui_value "$STATUS_TEXT")"
check "leaving Rewrite usable" "1" "$(ui_enabled "$TRANSLATE_BTN")"

section "the Model picker: Download opens the transform chooser, a pick is remembered apart"
reset_document
use_shipped_presets
a="$(make_transform_model humanizer-12B-8bit)"
b="$(make_transform_model humanizer-12B-4bit)"
open_transform_window
printf '%s\n%s\n' "$a" "$b" > "$(spool_dir)/modelpaths"
printf '%s' "$a" > "$(spool_dir)/model.dir"
printf '0' > "$(spool_dir)/picker_quiet"
pref_set ModelName translategemma-12b-4bit
"$OMC_OMC_SUPPORT_PATH/omc_dialog_control" "$OMC_ACTIONUI_WINDOW_UUID" "$TRANSLATE_BTN" omc_enable
omc_control "$MODEL_PICKER" 2
omc_run interp.transform.model.changed
check "the pick is the window's model" "$b" "$(spool_file model.dir)"
check "Rewrite goes off until the broker is respawned" "0" "$(ui_enabled "$TRANSLATE_BTN")"
check "remembered under the transform key" "humanizer-12B-4bit" "$(pref TransformModelName)"
check "the translator's saved model is untouched" "translategemma-12b-4bit" "$(pref ModelName)"
chains_reset
omc_control "$MODEL_PICKER" 3
omc_run interp.transform.model.changed
check "the sentinel opens the transform chooser" "1" "$(chain_asked interp.tmodels)"
check "not the translation one" "0" "$(chain_asked interp.models)"
check "and the selection is unchanged" "$b" "$(spool_file model.dir)"

section "the broker is spawned with the preset's sampling and server settings"
reset_document
use_test_presets
dir="$(make_transform_model humanizer-12B-8bit)"
/bin/mkdir -p "$(spool_dir)"
interp_tcall spawn_transform_broker "$(spool_dir)" "$dir" "$TEST_PRESETS/10-humanize.json" >/dev/null
wait_for_calls llama-server 1
wait_for_calls mlx-agent 1
check "the server gets the model's context size" "8192" "$(flag_number llama-server --ctx-size)"
check "top-k 0, as the card requires" "0" "$(flag_number llama-server --top-k)"
check "min-p 0" "0" "$(flag_number llama-server --min-p)"
check "the broker samples at temperature 1.0" "1" "$(flag_number mlx-agent --temperature)"
check "with top-p 0.95" "0.95" "$(flag_number mlx-agent --top-p)"
check "through the openai backend" "yes" "$(fake_arg mlx-agent openai)"
fakes_reset
interp_tcall spawn_transform_broker "$(spool_dir)" "$dir" "$TEST_PRESETS/20-small.json" >/dev/null
wait_for_calls llama-server 1
wait_for_calls mlx-agent 1
check "the chat-template option arrives as one argument" "yes" "$(fake_arg llama-server '{"enable_thinking":false}')"
check "a top_k that is not a number is dropped" "no" "$(fake_arg llama-server '--top-k')"
check "and nothing of it leaks into argv" "no" "$(fake_arg llama-server '--evil')"
check "the context size is the preset's" "4096" "$(flag_number llama-server --ctx-size)"
# chat_template_kwargs written as a JSON object rather than a string: plutil's raw output would be
# its key names, which llama-server cannot parse - so it is left out.
/usr/bin/sed 's/"chat_template_kwargs": "{\\"enable_thinking\\":false}"/"chat_template_kwargs": {"enable_thinking": false}/' \
    "$TEST_PRESETS/20-small.json" > "$OMCTEST_WORK/object-kwargs.json"
check "(the fixture really holds an object)" "yes" \
    "$(contains "$(/bin/cat "$OMCTEST_WORK/object-kwargs.json")" '"chat_template_kwargs": {')"
fakes_reset
interp_tcall spawn_transform_broker "$(spool_dir)" "$dir" "$OMCTEST_WORK/object-kwargs.json" >/dev/null
wait_for_calls llama-server 1
check "an object-valued chat_template_kwargs is not passed" "no" "$(fake_arg llama-server '--chat-template-kwargs')"

section "the transform chooser binds the transform library"
reset_document
use_shipped_presets
machine_ram_gb 32
omc_control_defaults models.window
omc_run interp.tmodels.init
check_status "init ran" 0
check_exists "its marker lives under the transform downloads" "$(transform_chooser_marker)"
check_absent "not under the translation downloads" "$(chooser_marker)"
check_exists "the transform library exists" "$(transforms_dir)"
check "the header names the kind" "Text Transform Models" "$(ui_value 900)"
wait_for_calls interp.models.load.sh 1
check "the catalog load was launched for this window" "$OMC_ACTIONUI_WINDOW_UUID" "$(fake_arg_at interp.models.load.sh 1)"
check "a handler in this window resolves the transform kind" "transform" \
    "$(interp_eval 'printf %s "$INTERP_KIND"')"
check "and the transform catalog" "$APP_RESOURCES/models.transform.catalog.tsv" \
    "$(interp_eval 'printf %s "$INTERP_CATALOG_TSV"')"
check "and the transform library" "$(transforms_dir)" "$(interp_eval 'printf %s "$MODELS_DIR"')"
omc_run interp.models.cancel
check_absent "closing it removes its marker" "$(transform_chooser_marker)"
check "after which the window resolves as translate again" "translate" \
    "$(interp_eval 'printf %s "$INTERP_KIND"')"

section "a download from the transform chooser tells the worker its kind"
reset_document
use_shipped_presets
omc_control_defaults models.window
omc_run interp.tmodels.init
/bin/mkdir -p "$(transform_cache_dir)"
printf 'best\thumanizer\tjialinyyzz\thumanizer-12B-8bit\tHumanizer 12B (8-bit)\t12669630368\t0\tRewrites.\n' \
    > "$(transform_cache_dir)/curated.tsv"
omc_trigger 2015
omc_run interp.model.download
wait_for_calls interp.download.worker.sh 1
check "the worker gets the repo" "humanizer-12B-8bit" "$(fake_arg_at interp.download.worker.sh 2)"
check "and the transform kind" "transform" "$(fake_arg_at interp.download.worker.sh 3)"
check_exists "its work dir is in the transform downloads" "$(transform_downloads_dir)/humanizer-12B-8bit"

section "a transformer's info sheet names its maker, GGUF build and license"
reset_document
use_shipped_presets
omc_control_defaults models.window
omc_run interp.tmodels.init
/bin/mkdir -p "$(transform_cache_dir)"
printf 'best\thumanizer\tjialinyyzz\thumanizer-12B-8bit\tHumanizer 12B (8-bit)\t12669630368\t0\tRewrites.\n' \
    > "$(transform_cache_dir)/curated.tsv"
omc_trigger 2013
omc_run interp.models.info
info_md="$(ui_value 4010)"
check "the maker is the repo's author" "yes" "$(contains "$info_md" "Created by jialinyyzz (Humanizer).")"
check "it is a GGUF build" "yes" "$(contains "$info_md" "GGUF build")"
check "the source is the real GGUF repo" "yes" "$(contains "$info_md" "jialinyyzz/humanizer-GGUF")"
check "not the translator's Gemma credit" "no" "$(contains "$info_md" "TranslateGemma")"
check "and the license is Apache 2.0, as in its NOTICE" "yes" "$(contains "$info_md" "Apache License")"

section "deleting from the transform chooser removes only the transformer"
reset_document
use_shipped_presets
# The same directory name in both libraries: the strongest test that the kind picks the library.
make_mlx_model humanizer-12B-8bit >/dev/null
make_transform_model humanizer-12B-8bit >/dev/null
omc_control_defaults models.window
omc_run interp.tmodels.init
/bin/mkdir -p "$(transform_cache_dir)"
printf 'best\thumanizer\tjialinyyzz\thumanizer-12B-8bit\tHumanizer 12B (8-bit)\t12669630368\t0\tRewrites.\n' \
    > "$(transform_cache_dir)/curated.tsv"
omc_trigger 2019
omc_run interp.models.delete
check_exists "the pending delete is stashed in the transform marker" "$(transform_chooser_marker)/pending.delete"
omc_run interp.models.delete.confirm
check_absent "the transformer is gone" "$(transforms_dir)/humanizer-12B-8bit"
check_exists "the translation library's same-named dir is not" "$(models_dir)/humanizer-12B-8bit"

section "a confirm resolved as the other kind deletes nothing"
reset_document
use_shipped_presets
make_transform_model humanizer-12B-8bit >/dev/null
make_mlx_model humanizer-12B-8bit >/dev/null
# A pending delete stashed by this window while it was a TRANSLATION chooser (in its translate
# marker)... and the window now resolving as a TRANSFORM chooser (a transform marker exists). The
# confirm looks for the pending file in the transform marker, finds none, and deletes nothing in
# either library - the kind it resolved never sees a request made under the other one.
/bin/mkdir -p "$(chooser_marker)"
printf 'humanizer-12B-8bit' > "$(chooser_marker)/pending.delete"
/bin/mkdir -p "$(transform_chooser_marker)"
omc_run interp.models.delete.confirm
check_exists "no pending file in the transform marker: the transformer survives" "$(transforms_dir)/humanizer-12B-8bit"
check_exists "and the translation model too" "$(models_dir)/humanizer-12B-8bit"

section "the fact check reports dropped numbers and a script switch, and passes clean text"
src="$(make_text_file check.src 'We sold 18,600 units, up 38% from 140 in 2024; a 6.5 m mirror.')"
bad="$(make_text_file check.bad 'Sold 18600 units, 38% more than 14, in 2024, with a 6 m mirror.')"
zh="$(make_text_file check.zh '我们卖出了18600台，增长38%，2024年140台，6.5米。')"
ok="$(make_text_file check.ok 'In 2024 we sold 18,600 units - 38% up on 140. Mirror: 6.5 m.')"
check "dropped and altered numbers are named, both ways" \
    "Check: 2 numbers from the original are missing: 140, 6.5; 2 numbers are not in the original: 14, 6." \
    "$(/usr/bin/perl "$APP_SCRIPTS/transform_check.pl" "$src" "$bad")"
check "a switch to Chinese is reported" "Check: The result switched to Chinese." \
    "$(/usr/bin/perl "$APP_SCRIPTS/transform_check.pl" "$src" "$zh")"
check "a faithful rewrite passes silently" "" "$(/usr/bin/perl "$APP_SCRIPTS/transform_check.pl" "$src" "$ok")"
check "thousands separators do not count as a change" "" \
    "$(/usr/bin/perl "$APP_SCRIPTS/transform_check.pl" "$ok" "$src")"
# The spike's real failure: a 2025 report's "July" became "July of 2022". Nothing was dropped.
src2="$(make_text_file check.src2 'In July we had only 0.4 inches of rain at four sites, so we plan a tenth site.')"
added="$(make_text_file check.added 'The July of 2022 brought 0.4 inches of rain to 4 sites; a 10th site is planned.')"
check "an invented number is named, spelled-out ones are not" "Check: 1 number is not in the original: 2022." \
    "$(/usr/bin/perl "$APP_SCRIPTS/transform_check.pl" "$src2" "$added")"
jargon="$(make_text_file check.jargon 'Restart the Kubernetes pod and clear the cache.')"
k8s="$(make_text_file check.k8s 'Restart the k8s pod and clear the cache.')"
check "a digit inside a name is not a number" "" "$(/usr/bin/perl "$APP_SCRIPTS/transform_check.pl" "$jargon" "$k8s")"
# Seen in the spike: "PostgreSQL 16" came back as "PostgreSQL cluster v.16" - the 16 is still there.
pg="$(make_text_file check.pg 'Migrated to the PostgreSQL 16 cluster.')"
pgv="$(make_text_file check.pgv 'Moved to a new PostgreSQL cluster v.16.')"
check "a number after a dot that follows no digit still counts" "" "$(/usr/bin/perl "$APP_SCRIPTS/transform_check.pl" "$pg" "$pgv")"
# Chinese writes digits straight after Han characters; those are still numbers.
zhsrc="$(make_text_file check.zhsrc '例如，2024年的一项研究显示，准确率达到了94.5%。')"
zhres="$(make_text_file check.zhres '据2024年的研究，准确率高达94.5%。')"
check "digits after Han characters still count" "" "$(/usr/bin/perl "$APP_SCRIPTS/transform_check.pl" "$zhsrc" "$zhres")"
zhbad="$(make_text_file check.zhbad '据2023年的研究，准确率高达94.5%。')"
check "and a changed one among them is caught" \
    "Check: 1 number from the original is missing: 2024; 1 number is not in the original: 2023." \
    "$(/usr/bin/perl "$APP_SCRIPTS/transform_check.pl" "$zhsrc" "$zhbad")"
long="$(make_text_file check.long "$(/usr/bin/awk 'BEGIN { for (i = 0; i < 30; i++) printf "Every paragraph here says something. " }')")"
short="$(make_text_file check.short 'Every paragraph here says something.')"
check "a result far shorter than its source is flagged" "yes" \
    "$(contains "$(/usr/bin/perl "$APP_SCRIPTS/transform_check.pl" "$long" "$short")" 'much shorter')"
check "a short source is too small to judge by length" "" \
    "$(/usr/bin/perl "$APP_SCRIPTS/transform_check.pl" "$short" "$(make_text_file check.tiny 'Says something.')")"

section "the Rewrite service hands its text to a new transform window"
reset_document
use_shipped_presets
omctest_setvar OMC_OBJ_TEXT "Selected words."
omc_run interp.service.transform.text
check "a transform window is opened" "1" "$(chain_asked interp.transform)"
handoff="$(transform_service_handoff)"
check "the selection travels in a file" "Selected words." "$(/bin/cat "$handoff" 2>/dev/null)"
check "not on the translator's key" "" "$(service_handoff)"
omctest_setvar OMC_OBJ_TEXT ""
make_transform_model humanizer-12B-8bit >/dev/null
open_transform_window
check "the window's editor receives it" "Selected words." "$(ui_value "$SRC_EDITOR")"
check "the handoff is consumed" "" "$(transform_service_handoff)"
check_absent "and its file removed" "$handoff"

reset_document
omctest_end
