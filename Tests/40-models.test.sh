#!/bin/sh
# Tests/40-models.test.sh - the model library and the model chooser.
#
# The chooser is the only place in the applet that deletes anything, and it
# deletes a directory holding several gigabytes that the user waited a long time
# to download. Its remove path is driven by a repo name read out of a FILE, and
# the guard in front of the rm -rf is the whole safety story - so that guard
# gets tested harder than anything else here.
#
# The card view ids are the other quiet hazard: they encode the row number
# arithmetically, and every per-card handler reverse-maps a trigger id back
# through that arithmetic. An off-by-one there acts on a different model than
# the one the user clicked.
. "${OMCTEST_LIB:?set OMCTEST_LIB, or run via: appletbuilder test}"
. "$OMCTEST_TESTS/lib.test.interp.sh"

# A curated card list, the shape interp_curate_models emits: one line per card,
# eight tab-separated fields. The row NUMBER is what card view ids encode, which
# is why the lookup is by line and why blank lines would break it.
write_curated() { # <"section|family|author|repo|label|size|heavy|desc"> ...
    local spec
    /bin/mkdir -p "$(cache_dir)"
    : > "$(cache_dir)/curated.tsv"
    for spec; do
        printf '%s\n' "$spec" | /usr/bin/tr '|' '\t' >> "$(cache_dir)/curated.tsv"
    done
}

# The chooser window as it is after its cards have been built.
open_chooser() {
    reset_document
    machine_ram_gb 32
    omc_control_defaults models.window
    omc_run interp.models.init
}

section "an installed model is recognized by either engine's shape"
reset_document
mlx="$(make_mlx_model translategemma-12b-4bit)"
gguf="$(make_gguf_model hy-mt2-7b-q4)"
empty="$(make_empty_model_dir abandoned-download)"
check "an MLX safetensors dir counts"  "yes" "$(interp_is model_installed_at "$mlx")"
check "a GGUF dir counts"              "yes" "$(interp_is model_installed_at "$gguf")"
check "an empty directory does not"    "no"  "$(interp_is model_installed_at "$empty")"
check "the MLX engine is reported"     "mlx"  "$(interp_call model_engine_of "$mlx")"
check "and the GGUF one"               "gguf" "$(interp_call model_engine_of "$gguf")"
# The default is mlx so that anything unrecognized keeps the pre-GGUF behavior
# rather than being routed to a llama-server that cannot load it.
check "an unrecognized dir defaults to mlx" "mlx" "$(interp_call model_engine_of "$empty")"

section "the installed list skips what is not a model, and does not repeat itself"
listed="$(interp_call list_model_dirs)"
check "both models are listed" "2" "$(printf '%s\n' "$listed" | /usr/bin/grep -c '')"
check "the empty directory is not" "0" \
    "$(printf '%s\n' "$listed" | /usr/bin/grep -c 'abandoned-download')"
# The enumeration walks translategemma-* first and then everything, so without
# de-duplication a TranslateGemma directory would appear twice.
check "the translategemma dir appears once" "1" \
    "$(printf '%s\n' "$listed" | /usr/bin/grep -c 'translategemma-12b-4bit')"
check "and it comes first" "yes" \
    "$(contains "$(printf '%s\n' "$listed" | /usr/bin/sed -n 1p)" translategemma)"
check "resolve_model_dir agrees with the head of that list" \
    "$(printf '%s\n' "$listed" | /usr/bin/sed -n 1p)" "$(interp_call resolve_model_dir)"

section "families and labels are read off the directory name"
check "TranslateGemma"      "translategemma" "$(interp_call model_family_of translategemma-12b-4bit)"
check "MiLMMT-46"           "milmmt"         "$(interp_call model_family_of MiLMMT-46-12B-4bit)"
check "Hy-MT2, hyphenated"  "hymt"           "$(interp_call model_family_of Hy-MT2-7B-Q4)"
check "Hy-MT2, run together" "hymt"          "$(interp_call model_family_of hymt-7b)"
check "anything else"       "generic"        "$(interp_call model_family_of some-other-model)"
# Repo names differ in case between families (TranslateGemma uses -12b-, MiLMMT
# uses -12B-), so the parsing is case-insensitive on both sides.
check "a label is built from params and quant" "TranslateGemma 12B (4-bit)" \
    "$(interp_call model_display_label "$(models_dir)/translategemma-12b-4bit")"
check "case does not matter"                   "MiLMMT-46 12B (4-bit)" \
    "$(interp_call model_display_label "$(models_dir)/MiLMMT-46-12B-4bit")"
check "a name it cannot parse falls back to itself" "mystery-model" \
    "$(interp_call model_display_label "$(models_dir)/mystery-model")"

section "card view ids and row numbers are exact inverses"
check "row 0's base"  "2000" "$(interp_call interp_card_base_id 0)"
check "row 1's base"  "2010" "$(interp_call interp_card_base_id 1)"
check "row 7's base"  "2070" "$(interp_call interp_card_base_id 7)"
check "a base maps back"        "7" "$(interp_call interp_card_row_of_id 2070)"
# Every id in a card's block - title, badge, description, size, and the four
# buttons - has to map back to the SAME row, because a handler is given whichever
# one the user clicked.
check "so does the download button" "7" "$(interp_call interp_card_row_of_id 2075)"
check "and the info button"         "7" "$(interp_call interp_card_row_of_id 2076)"
check "and the delete button"       "7" "$(interp_call interp_card_row_of_id 2079)"
check "the next row starts a new block" "8" "$(interp_call interp_card_row_of_id 2080)"

section "a curated row is looked up by line, and a bad row number yields nothing"
write_curated \
  "best|translategemma|abracode|translategemma-27b-8bit|TranslateGemma 27B (8-bit)|18000000000|1|Best quality." \
  "recommended|milmmt|abracode|milmmt-46-12b-4bit|MiLMMT-46 12B (4-bit)|7000000000|0|Near-top quality."
check "row 1"        "best" "$(interp_call curated_row "$(cache_dir)/curated.tsv" 1 | /usr/bin/cut -f1)"
check "row 2"        "recommended" "$(interp_call curated_row "$(cache_dir)/curated.tsv" 2 | /usr/bin/cut -f1)"
check "row 0"        "" "$(interp_call curated_row "$(cache_dir)/curated.tsv" 0)"
check "a row past the end" "" "$(interp_call curated_row "$(cache_dir)/curated.tsv" 99)"
check "a non-numeric row"  "" "$(interp_call curated_row "$(cache_dir)/curated.tsv" abc)"

section "family display names and blurbs"
check "TranslateGemma" "TranslateGemma" "$(interp_call family_display_name translategemma)"
check "MiLMMT-46"      "MiLMMT-46"      "$(interp_call family_display_name milmmt)"
check "Hy-MT2"         "Hy-MT2"         "$(interp_call family_display_name hymt)"
check "an unknown family passes through" "whatever" "$(interp_call family_display_name whatever)"
check "every shipped family has a blurb" "yes" \
    "$([ -n "$(interp_call family_blurb translategemma)" ] &&
       [ -n "$(interp_call family_blurb milmmt)" ] &&
       [ -n "$(interp_call family_blurb hymt)" ] && echo yes || echo no)"
check "an unknown one has none" "" "$(interp_call family_blurb whatever)"
# Card fields are interpolated into JSON, so a quote or a backslash in one would
# produce an unparseable element rather than a wrong-looking card.
check "no blurb carries a character that would break the JSON" "0" \
    "$(for fam in translategemma milmmt hymt; do interp_call family_blurb "$fam"; done \
        | /usr/bin/grep -c '["\\]')"

section "sizes are rendered, and an unknown size says so"
check "a real size"       "7.0 GB" "$(interp_call bytes_to_gb 7000000000)"
check "zero is unknown"   "?"      "$(interp_call bytes_to_gb 0)"
check "so is empty"       "?"      "$(interp_call bytes_to_gb '')"
check "and so is garbage" "?"      "$(interp_call bytes_to_gb 'not-a-number')"

section "the chooser opens with its sections hidden and a load in flight"
open_chooser
check_status "init ran" 0
check_exists "the chooser got a marker directory" "$(chooser_marker)"
check_exists "and a cache directory"              "$(cache_dir)"
# The sections are empty until the cards are built, and an empty titled box
# reads as "there is nothing in this category".
check "Best Quality is hidden"  "0" "$(ui_visible "$SECTION_BEST_ID")"
check "Recommended is hidden"   "0" "$(ui_visible "$SECTION_RECOMMENDED_ID")"
check "Faster is hidden"        "0" "$(ui_visible "$SECTION_FASTER_ID")"
check "the status line explains the wait" "Finding the best models for your Mac…" \
    "$(ui_value "$CHOOSER_STATUS_ID")"
# The catalog query is network work, so it is backgrounded and the window paints
# immediately. All this handler is responsible for is launching the two workers.
wait_for_calls interp.models.load.sh 1
wait_for_calls interp.models.poll.sh 1
check "the catalog loader was launched" "1" "$(fake_calls interp.models.load.sh)"
check "for this window"                 "$OMC_ACTIONUI_WINDOW_UUID" \
    "$(fake_arg_at interp.models.load.sh 1)"
check "and the download-state poller too" "1" "$(fake_calls interp.models.poll.sh)"
check "for this window"                   "$OMC_ACTIONUI_WINDOW_UUID" \
    "$(fake_arg_at interp.models.poll.sh 1)"
# It must not do the network work itself.
check "no catalog request was made from the handler" "0" "$(fake_calls curl)"

section "Refresh re-runs the load without touching anything else"
omc_run interp.models.refresh
wait_for_calls interp.models.load.sh 2
check "the loader ran again" "2" "$(fake_calls interp.models.load.sh)"
check "the status line says so" "Refreshing…" "$(ui_value "$CHOOSER_STATUS_ID")"
check "and the poller was not restarted" "1" "$(fake_calls interp.models.poll.sh)"

section "closing the chooser stops its poller and leaves downloads running"
omc_run interp.models.cancel
# The marker directory bounds the poller's lifetime: it loops on its existence.
check_absent "the marker directory is gone" "$(chooser_marker)"
# In-progress downloads are UI-decoupled on purpose, so reopening the chooser
# reconnects to them rather than restarting them.
check_exists "the downloads directory survives" "$(downloads_dir)"

section "Download spawns one worker, for the row that was clicked"
open_chooser
write_curated \
  "best|translategemma|abracode|translategemma-27b-8bit|TranslateGemma 27B (8-bit)|1000|1|Best quality." \
  "recommended|milmmt|abracode|milmmt-46-12b-4bit|MiLMMT-46 12B (4-bit)|1000|0|Near-top quality."
# Row 2's Download button. The id encodes the row, which is the only thing that
# tells the handler which model to fetch.
omc_trigger "$(( $(interp_call interp_card_base_id 2) + 5 ))"
omc_run interp.model.download
wait_for_calls interp.download.worker.sh 1
check "one worker was launched" "1" "$(fake_calls interp.download.worker.sh)"
check "for the second row's author" "abracode" "$(fake_arg_at interp.download.worker.sh 1)"
check "and its repo"                "milmmt-46-12b-4bit" \
    "$(fake_arg_at interp.download.worker.sh 2)"
check "the work directory was claimed" "preparing" \
    "$(/bin/cat "$(downloads_dir)/milmmt-46-12b-4bit/state" 2>/dev/null)"
check "and the worker's pid recorded" "yes" \
    "$([ -s "$(downloads_dir)/milmmt-46-12b-4bit/worker.pid" ] && echo yes || echo no)"
check "the button was disabled"      "0" \
    "$(ui_enabled "$(( $(interp_call interp_card_base_id 2) + 5 ))")"
check "the dispatch lock was released" "no" \
    "$([ -d "$(downloads_dir)/milmmt-46-12b-4bit/dispatch.lock" ] && echo yes || echo no)"

section "a second click while a worker is alive does not start another"
# The worker's pid is argv-verified, so a LIVE process whose argv looks like the
# worker is what "already downloading" means. This test owns the process.
spawn_fake_worker
live="$FAKE_WORKER_PID"
printf '%s' "$live" > "$(downloads_dir)/milmmt-46-12b-4bit/worker.pid"
check "the stand-in worker really is running" "yes" \
    "$(/bin/kill -0 "$live" 2>/dev/null && echo yes || echo no)"
printf 'downloading' > "$(downloads_dir)/milmmt-46-12b-4bit/state"
omc_trigger "$(( $(interp_call interp_card_base_id 2) + 5 ))"
omc_run interp.model.download
check "still just the one worker" "1" "$(fake_calls interp.download.worker.sh)"
/bin/kill -TERM "$live" 2>/dev/null
wait "$live" 2>/dev/null

section "an in-flight state whose worker died is respawned, not left stuck"
# An app quit mid-transfer leaves state=downloading with a dead pid. Treating
# that as an active download would strand the model forever; curl -C - resumes
# the partial bytes in staging.
printf '999999' > "$(downloads_dir)/milmmt-46-12b-4bit/worker.pid"
printf 'downloading' > "$(downloads_dir)/milmmt-46-12b-4bit/state"
omc_trigger "$(( $(interp_call interp_card_base_id 2) + 5 ))"
omc_run interp.model.download
wait_for_calls interp.download.worker.sh 2
check "a fresh worker was launched" "2" "$(fake_calls interp.download.worker.sh)"

section "an already-installed model is not downloaded again"
make_mlx_model milmmt-46-12b-4bit >/dev/null
/bin/rm -rf "$(downloads_dir)/milmmt-46-12b-4bit"
before="$(fake_calls interp.download.worker.sh)"
omc_trigger "$(( $(interp_call interp_card_base_id 2) + 5 ))"
omc_run interp.model.download
check "no worker was launched" "$before" "$(fake_calls interp.download.worker.sh)"
check "the card says Installed" "Installed" \
    "$(ui_value "$(( $(interp_call interp_card_base_id 2) + 2 ))")"
check "and its button is off"   "0" \
    "$(ui_enabled "$(( $(interp_call interp_card_base_id 2) + 5 ))")"

section "Download ignores a trigger that is not a card id"
open_chooser
write_curated \
  "best|translategemma|abracode|tg-a|TranslateGemma A|1000|1|Best." \
  "recommended|milmmt|abracode|mm-b|MiLMMT B|1000|0|Near-top."
# Stated honestly: the "-gt 2000" guard in the handler cannot be shown to
# change an outcome, and this section does not claim to test it. Every id it
# rejects is <= 2000, which reverse-maps to row 0 or a negative row, and
# curated_row rejects those too - so with the guard deleted the handler still
# launches nothing. What is pinned here is the OUTCOME for a trigger that is not
# a card, together with a positive control so it is not passing against a
# handler that never launches anything at all.
omc_trigger 910
omc_run interp.model.download
check "a chooser control's id starts nothing" "0" \
    "$(fake_calls interp.download.worker.sh)"
omc_trigger ""
omc_run interp.model.download
check "nor an empty trigger" "0" "$(fake_calls interp.download.worker.sh)"
omc_trigger "$(( $(interp_call interp_card_base_id 1) + 5 ))"
omc_run interp.model.download
wait_for_calls interp.download.worker.sh 1
check "but a real card id does" "1" "$(fake_calls interp.download.worker.sh)"

section "Delete asks first, and deletes nothing by itself"
open_chooser
write_curated \
  "best|translategemma|abracode|translategemma-27b-8bit|TranslateGemma 27B (8-bit)|1000|1|Best." \
  "recommended|milmmt|abracode|milmmt-46-12b-4bit|MiLMMT-46 12B (4-bit)|1000|0|Near-top."
victim="$(make_mlx_model milmmt-46-12b-4bit)"
omc_trigger "$(( $(interp_call interp_card_base_id 2) + 9 ))"
omc_run interp.models.delete
wait_for_calls interp.models.load.sh 1
check_exists "the model is still installed" "$victim/config.json"
check "the user was asked, by name" "Delete MiLMMT-46 12B (4-bit)?" "$(ui_alert_title)"
check "the message says it can be downloaded again" "yes" \
    "$(contains "$(ui_alert_message)" 'download it again later')"
# Alert buttons carry no per-row context, which is why the pending model is
# stashed in the marker directory for the confirm handler to read.
check "the pending model was recorded" "milmmt-46-12b-4bit" \
    "$(/bin/cat "$(chooser_marker)/pending.delete" 2>/dev/null)"
check "the Delete button is wired to the confirm command" "interp.models.delete.confirm" \
    "$(ui_alert_action Delete)"

section "confirming removes the model and its download leftovers"
/bin/mkdir -p "$(downloads_dir)/milmmt-46-12b-4bit"
printf 'log\n' > "$(downloads_dir)/milmmt-46-12b-4bit.log"
omc_run interp.models.delete.confirm
check_absent "the model is gone"          "$victim"
check_absent "so is its download work dir" "$(downloads_dir)/milmmt-46-12b-4bit"
check_absent "and its log"                 "$(downloads_dir)/milmmt-46-12b-4bit.log"
check "the status line says what happened" "Deleted milmmt-46-12b-4bit." \
    "$(ui_value "$CHOOSER_STATUS_ID")"
# The cards are rebuilt so the row reverts to a Download button.
wait_for_calls interp.models.load.sh 2
check "the cards were rebuilt" "yes" \
    "$([ "$(fake_calls interp.models.load.sh)" -ge 2 ] && echo yes || echo no)"
# The pending file is consumed, so a stray second confirm cannot delete again.
check_absent "the pending record was consumed" "$(chooser_marker)/pending.delete"

section "a confirm with nothing pending deletes nothing"
keeper="$(make_mlx_model translategemma-27b-8bit)"
omc_run interp.models.delete.confirm
check_exists "the other model is untouched" "$keeper/config.json"

section "the delete guard refuses anything that is not a bare directory name"
# The pending file is read from disk, so a corrupted or crafted one must never
# reach the rm -rf as a path. The vectors are aimed at things a bypass would
# ACTUALLY destroy, which the obvious ones are not: "../../etc" and ".hidden"
# name paths that do not exist under Models, so rm is a silent no-op with or
# without the guard, and "." and ".." are refused by rm itself rather than by
# the applet. A section built on those passes with the guard deleted - measured.
#
# So: a canary one level up from Models, which "../canary" would reach, and a
# real nested directory, which "sub/dir" would reach.
canary="$(app_support)/canary"
/bin/mkdir -p "$canary" "$(models_dir)/sub/dir"
printf 'do not delete me' > "$canary/keep.txt"
for bad in "../canary" "sub/dir" ".." "."; do
    /bin/mkdir -p "$(chooser_marker)"
    printf '%s' "$bad" > "$(chooser_marker)/pending.delete"
    omc_run interp.models.delete.confirm
    check "refused: $bad - the canary survived" "do not delete me" \
        "$(/bin/cat "$canary/keep.txt" 2>/dev/null)"
    check "refused: $bad - the nested directory survived" "yes" \
        "$([ -d "$(models_dir)/sub/dir" ] && echo yes || echo no)"
    check "refused: $bad - the installed model survived" "yes" \
        "$([ -f "$keeper/config.json" ] && echo yes || echo no)"
done
# The positive control: the same handler DOES delete a legitimate bare name, so
# the refusals above are not passing against a handler that never deletes.
printf 'translategemma-27b-8bit' > "$(chooser_marker)/pending.delete"
omc_run interp.models.delete.confirm
check_absent "but a bare directory name goes through" "$keeper"
check "and the canary is still untouched" "do not delete me" \
    "$(/bin/cat "$canary/keep.txt" 2>/dev/null)"

section "Reveal opens the model directory, and only when it is there"
open_chooser
write_curated "best|translategemma|abracode|translategemma-27b-8bit|TranslateGemma|1000|1|Best."
omc_trigger "$(( $(interp_call interp_card_base_id 1) + 8 ))"
omc_run interp.models.reveal
check "nothing was revealed for a model that is not installed" "0" "$(fake_calls open)"
installed="$(make_mlx_model translategemma-27b-8bit)"
# The trigger family is ONE-SHOT: omc_run clears it, exactly as the engine does
# after dispatching an event. A second dispatch needs its own.
omc_trigger "$(( $(interp_call interp_card_base_id 1) + 8 ))"
omc_run interp.models.reveal
check "and the installed one was" "yes" "$(fake_arg open "$installed" 1)"
check "with -R" "yes" "$(fake_arg open -R 1)"

section "the Model picker resolves an index to a model directory"
reset_document
a="$(make_mlx_model translategemma-12b-4bit)"
b="$(make_gguf_model hy-mt2-7b-q4)"
/bin/mkdir -p "$(spool_dir)"
# modelpaths is the poller's index file: one resolved path per line, in picker
# order. The handler maps the picker's 1-based index through it.
printf '%s\n%s\n' "$a" "$b" > "$(spool_dir)/modelpaths"
omc_fire interp.model.changed "$MODEL_PICKER" 2
check "the second model was selected" "$b" "$(model_dir_of)"
# Persisted by NAME rather than path, so a moved Models directory cannot pin a
# dead path.
check "and remembered by directory name" "hy-mt2-7b-q4" "$(pref ModelName)"

section "the picker's last row is the Download sentinel, not a model"
omc_fire interp.model.changed "$MODEL_PICKER" 3
check "the chooser was opened" "1" "$(chain_asked interp.models)"
# The picker is snapped back to the current model, or it would sit there
# apparently stuck on "Download models…".
check "and the picker was put back on the current model" "2" "$(ui_value "$MODEL_PICKER")"
check "the selection itself did not change" "$b" "$(model_dir_of)"

section "the picker ignores what it should ignore"
chains_reset
omc_fire interp.model.changed "$MODEL_PICKER" "not-a-number"
check "a non-numeric index" "$b" "$(model_dir_of)"
check "and it opened nothing" "0" "$(chain_asked interp.models)"
# Re-selecting what is already selected is what the poller's own refreshes look
# like, and rewriting model.dir would make the poller restart the broker.
before_mtime="$(/usr/bin/stat -f %m "$(spool_dir)/model.dir")"
omc_fire interp.model.changed "$MODEL_PICKER" 2
check "re-selecting the same model changes nothing" "$before_mtime" \
    "$(/usr/bin/stat -f %m "$(spool_dir)/model.dir")"

section "a picker fire inside the poller's quiet window is not a user choice"
pref_set ModelName "hy-mt2-7b-q4"
printf '%s' "$(( $(/bin/date +%s) + 5 ))" > "$(spool_dir)/picker_quiet"
omc_fire interp.model.changed "$MODEL_PICKER" 1
# The poller's own option and value updates fire this handler. Honoring them
# would let an auto-selection overwrite the model the user chose.
check "the selection is unchanged"  "$b" "$(model_dir_of)"
check "and so is the preference"    "hy-mt2-7b-q4" "$(pref ModelName)"

section "the RAM-aware curation, which decides what a Mac is offered"
# The most intricate logic in the applet, and the only section that gives the
# sysctl fake a positive control: without one, "no catalog request was made"
# elsewhere reads 0 because nothing in the suite can make it non-zero, and a
# seam that had been dropped would still look green while the suite quietly
# started talking to Hugging Face.
#
# The cache file is the shape interp_fetch_catalog produces:
#   family  author  repo  params  bits  size_bytes
reset_document
cache="$(cache_dir)/curated-input.tsv"
/bin/mkdir -p "$(cache_dir)"
{
    printf 'translategemma\tabracode\ttranslategemma-27b-8bit\t27\t8\t28000000000\n'
    printf 'translategemma\tabracode\ttranslategemma-27b-4bit\t27\t4\t15000000000\n'
    printf 'translategemma\tabracode\ttranslategemma-12b-4bit\t12\t4\t7000000000\n'
    printf 'translategemma\tabracode\ttranslategemma-4b-8bit\t4\t8\t4500000000\n'
} > "$cache"

machine_ram_gb 64
curated="$(interp_call interp_curate_models "$cache")"
check "sysctl really was consulted" "1" "$(fake_calls sysctl)"
check "a 64 GB Mac is offered the largest variant first" "best" \
    "$(printf '%s\n' "$curated" | /usr/bin/sed -n 1p | /usr/bin/cut -f1)"
check "and that is the 8-bit 27B" "translategemma-27b-8bit" \
    "$(printf '%s\n' "$curated" | /usr/bin/sed -n 1p | /usr/bin/cut -f4)"
check "the card label is built from params and quant" "TranslateGemma 27B (8-bit)" \
    "$(printf '%s\n' "$curated" | /usr/bin/sed -n 1p | /usr/bin/cut -f5)"
check "every row carries the family blurb" "0" \
    "$(printf '%s\n' "$curated" | /usr/bin/awk -F'\t' '$8 == "" { n++ } END { print n+0 }')"

# The same catalog on a small Mac must not offer what will not load: peak is
# weights*1.15 + 1.5 GB and the offer ceiling is 92% of RAM, so a 28 GB model
# needs far more than 16 GB.
machine_ram_gb 16
small="$(interp_call interp_curate_models "$cache")"
check "a 16 GB Mac is not offered the 27B 8-bit" "0" \
    "$(printf '%s\n' "$small" | /usr/bin/grep -c 'translategemma-27b-8bit')"
check "nor the 27B 4-bit"                        "0" \
    "$(printf '%s\n' "$small" | /usr/bin/grep -c 'translategemma-27b-4bit')"
check "but it is offered something"              "yes" \
    "$([ -n "$small" ] && echo yes || echo no)"
# The positive control for the two zeros above: the same variants ARE offered
# when the machine can hold them.
check "while the 64 GB Mac was offered the 27B" "1" \
    "$(printf '%s\n' "$curated" | /usr/bin/grep -c 'translategemma-27b-8bit')"

machine_ram_gb 4
# Nothing in this catalog fits 4 GB, and what the curation does then is emit no
# rows. It still exits 0 - the exit status comes from the pipeline's tail, not
# from the awk that decided there was nothing to offer - so the assertion is on
# the OUTPUT, which is what the chooser actually consumes.
check "a machine too small for anything is offered no cards" "" \
    "$(interp_call interp_curate_models "$cache")"
check "and an empty catalog is refused outright" "no" \
    "$(interp_is interp_curate_models "$(cache_dir)/nonexistent.tsv")"

section "a repo's download size comes from the Hugging Face tree API"
# The only positive control the curl fake has. The response is the shape
# hf_repo_size_bytes parses: plutil -p output of the tree JSON, where an LFS
# entry reports its real size at the top level AND again nested, so only the
# first "size" per object may be counted.
reset_document
fake_answer curl 0 '200'
check "a failed probe reports zero rather than guessing" "0" \
    "$(interp_call hf_repo_size_bytes abracode/does-not-exist)"
check "and curl really was the thing asked" "1" "$(fake_calls curl)"
check "with the repo in the URL" "1" \
    "$(fake_mentions curl 'api/models/abracode/does-not-exist/tree/main')"
# A 404 is the NORMAL case for a planned-but-unpublished catalog entry, so it
# must fail fast rather than burning retries.
reset_document
fake_answer curl 0 '404'
check "a 404 answers zero"        "0" "$(interp_call hf_repo_size_bytes abracode/planned)"
check "after exactly one request" "1" "$(fake_calls curl)"

section "cumulative: no handler wrote to a view id the window does not declare"
check "no undeclared ids" "" "$(ui_unknown_writes)"
check "the harness detected no misuse" "" "$(ui_errors)"

omctest_end
