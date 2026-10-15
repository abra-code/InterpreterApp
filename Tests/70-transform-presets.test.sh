#!/bin/sh
# Tests/70-transform-presets.test.sh - the editing presets that run on a general instruct model
# (Gemma 4 12B instruct), and the per-preset choice of post-run checks.
#
# The spike's two expensive lessons are pinned here. Gemma 4's chat template thinks whenever
# llama-server enables thinking, which it does by default: the broker keeps only the answer, so a
# preset without enable_thinking false spends its whole token budget on hidden reasoning and
# returns an EMPTY result. And a preset whose job is to shorten text must not be told its result
# is "much shorter than the original".
. "${OMCTEST_LIB:?set OMCTEST_LIB, or run via: appletbuilder test}"
. "$OMCTEST_TESTS/lib.test.interp.sh"

PRESETS="$APP_RESOURCES/Transformers"
CATALOG="$APP_RESOURCES/models.transform.catalog.tsv"

section "the Gemma 4 family is in the catalog, named and described"
check "two Gemma 4 variants are offered" "2" \
    "$(/usr/bin/awk -F'\t' '$1 == "gemma4it" { n++ } END { print n + 0 }' "$CATALOG")"
check "a GGUF row each" "2" \
    "$(/usr/bin/awk -F'\t' '$1 == "gemma4it" && $6 == "gguf" { n++ } END { print n + 0 }' "$CATALOG")"
check "the family has a display name" "Gemma 4" "$(interp_call family_display_name gemma4it)"
check "and a description" "yes" "$([ -n "$(interp_call family_blurb gemma4it)" ] && echo yes || echo no)"
check "which cannot break the card JSON" "0" "$(interp_call family_blurb gemma4it | /usr/bin/grep -c '["\\]')"
reset_document
q8="$(make_transform_model gemma-4-12B-it-8bit)"
check "an installed variant is labeled" "Gemma 4 12B (8-bit)" "$(interp_tcall transform_display_label "$q8")"
check "and belongs to its family" "gemma4it" "$(interp_tcall transform_family_of "$q8")"

section "every Gemma 4 preset is a chat preset with thinking turned off"
n=0
for f in "$PRESETS"/*.json; do
    [ "$(/usr/bin/plutil -extract family raw -o - "$f")" = gemma4it ] || continue
    n=$((n + 1))
    name="$(/usr/bin/basename "$f")"
    check "$name disables thinking" '{"enable_thinking":false}' \
        "$(/usr/bin/plutil -extract server.chat_template_kwargs raw -o - "$f" 2>/dev/null | /usr/bin/tr -d ' ')"
    check "$name sends chat messages" "yes" \
        "$(/usr/bin/plutil -extract job.messages json -o - "$f" >/dev/null 2>&1 && echo yes || echo no)"
    check "$name puts the text in the user turn" "{{chunk}}" \
        "$(/usr/bin/plutil -extract job.messages.1.content raw -o - "$f" 2>/dev/null)"
    check "$name gives the model its instructions as a system turn" "system" \
        "$(/usr/bin/plutil -extract job.messages.0.role raw -o - "$f" 2>/dev/null)"
done
check "there are Gemma 4 presets at all" "yes" "$([ "$n" -ge 1 ] && echo yes || echo no)"

section "Humanize also runs on Gemma 4, for text in any language"
hg="$PRESETS/15-humanize-gemma.json"
check "it is Humanize, not a transform of its own" "humanize Humanize" \
    "$(/usr/bin/plutil -extract id raw -o - "$hg") $(/usr/bin/plutil -extract name raw -o - "$hg")"
check "it is a Gemma 4 preset" "gemma4it" "$(/usr/bin/plutil -extract family raw -o - "$hg")"
check "it sits right after Humanize in the picker" "10-humanize.json 15-humanize-gemma.json" \
    "$(for f in "$PRESETS"/*.json; do /usr/bin/basename "$f"; done | /usr/bin/sed -n '1,2p' | /usr/bin/tr '\n' ' ' | /usr/bin/sed 's/ $//')"
# The spike's two failures with the plain Humanize prompt on Gemma 4: emails cut to half their
# length, and a numbered list turned into prose that lost its numbers.
check "it is told not to summarize" "yes" \
    "$(contains "$(/usr/bin/plutil -extract job.messages.0.content raw -o - "$hg")" 'Do not summarize')"
check "and to keep a list's numbers" "yes" \
    "$(contains "$(/usr/bin/plutil -extract job.messages.0.content raw -o - "$hg")" 'keep lists as lists, with their numbers')"
check "every check runs, length included" "" "$(/usr/bin/plutil -extract checks raw -o - "$hg" 2>/dev/null)"
check "the Gemma 4 card says it humanizes" "yes" "$(contains "$(interp_call family_blurb gemma4it)" humanizes)"

section "preset ids and names are unique per transform, and checks name only known checks"
# The files of one transform (its variants, one per model family) share its id and name; the
# picker lists the transform once. Two transforms must not share either.
check "no transform has two files for one family" "" \
    "$(for f in "$PRESETS"/*.json; do printf '%s %s\n' "$(/usr/bin/plutil -extract id raw -o - "$f")" "$(/usr/bin/plutil -extract family raw -o - "$f")"; done | /usr/bin/sort | /usr/bin/uniq -d)"
check "the files of one transform share its name, and no two transforms share one" "" \
    "$(for f in "$PRESETS"/*.json; do printf '%s %s\n' "$(/usr/bin/plutil -extract id raw -o - "$f")" "$(/usr/bin/plutil -extract name raw -o - "$f")"; done | /usr/bin/sort -u \
        | /usr/bin/awk '{ id = $1; $1 = ""; ids[id]++; names[$0]++ } END { for (i in ids) if (ids[i] > 1) print i; for (n in names) if (names[n] > 1) print n }')"
check "every checks word is numbers, added-numbers, script, length or language" "" \
    "$(for f in "$PRESETS"/*.json; do /usr/bin/plutil -extract checks raw -o - "$f" 2>/dev/null; echo; done \
        | /usr/bin/tr " " "\n" | /usr/bin/grep -v -x -e "" -e numbers -e added-numbers -e script -e length -e language)"

section "a preset can turn the length check off, and only that"
long="$(make_text_file p.long "$(/usr/bin/awk 'BEGIN { for (i = 0; i < 30; i++) printf "Every paragraph here says something about 42 things. " }')")"
short="$(make_text_file p.short 'It says something about 41 things.')"
check "by default a much shorter result is flagged" "yes" \
    "$(contains "$(/usr/bin/perl "$APP_SCRIPTS/transform_check.pl" "$long" "$short")" 'much shorter')"
check "with length off it is not" "no" \
    "$(contains "$(/usr/bin/perl "$APP_SCRIPTS/transform_check.pl" --checks 'numbers script' "$long" "$short")" 'much shorter')"
check "but the numbers are still checked" "yes" \
    "$(contains "$(/usr/bin/perl "$APP_SCRIPTS/transform_check.pl" --checks 'numbers script' "$long" "$short")" '42')"
check "and with numbers off they are not" "" \
    "$(/usr/bin/perl "$APP_SCRIPTS/transform_check.pl" --checks 'script' "$long" "$short")"

section "a formal rewrite may spell numbers out in full; a wrong or dropped one is still caught"
# Seen in the spike: "Make formal" turned "40k rows ... around 2am" into "40,000 rows ... 2:00 AM".
casual="$(make_text_file k.src 'The script choked on like 40k rows, so we rolled back around 2am.')"
formal="$(make_text_file k.formal 'The script failed on approximately 40,000 rows; a rollback was performed at 2:00 AM.')"
check "40k written as 40,000 and 2am as 2:00 are the same numbers" "" \
    "$(/usr/bin/perl "$APP_SCRIPTS/transform_check.pl" "$casual" "$formal")"
wrong="$(make_text_file k.wrong 'The script failed on approximately 4,000 rows; a rollback was performed at 2:00 AM.')"
check "40k written as 4,000 is caught both ways" \
    "Check: 1 number from the original is missing: 40; 1 number is not in the original: 4,000." \
    "$(/usr/bin/perl "$APP_SCRIPTS/transform_check.pl" "$casual" "$wrong")"
dropped="$(make_text_file k.dropped 'The script failed on many rows; a rollback was performed at 2:00 AM.')"
check "and dropping it is caught" "Check: 1 number from the original is missing: 40." \
    "$(/usr/bin/perl "$APP_SCRIPTS/transform_check.pl" "$casual" "$dropped")"
# Only a clock's minutes are excused: an hour that changed is still a new number.
hour="$(make_text_file k.hour 'The script failed on approximately 40,000 rows; a rollback was performed at 3:00 AM.')"
check "a changed hour is still caught" "Check: 1 number from the original is missing: 2; 1 number is not in the original: 3." \
    "$(/usr/bin/perl "$APP_SCRIPTS/transform_check.pl" "$casual" "$hour")"
# And only minutes: any other number after a colon is new.
scale="$(make_text_file k.scale 'The script failed on approximately 40,000 rows; a rollback was performed at 2:00 AM, on a 2:250 scale.')"
check "a number after a colon that is not minutes is caught" "Check: 1 number is not in the original: 250." \
    "$(/usr/bin/perl "$APP_SCRIPTS/transform_check.pl" "$casual" "$scale")"
# "40k" vouches for its own 40 only: a separate plain 40 that was dropped is still missing.
both="$(make_text_file k.both 'We have 40 servers and 40k rows.')"
onlyk="$(make_text_file k.onlyk 'We have 40,000 rows.')"
check "a plain 40 next to a 40k is checked on its own" "Check: 1 number from the original is missing: 40." \
    "$(/usr/bin/perl "$APP_SCRIPTS/transform_check.pl" "$both" "$onlyk")"

section "a checks list that names no known check runs every check"
check "a misspelled list does not switch the checks off" "yes" \
    "$(contains "$(/usr/bin/perl "$APP_SCRIPTS/transform_check.pl" --checks 'lenght' "$long" "$short")" 'much shorter')"
check "an unknown word beside a known one is ignored" "no" \
    "$(contains "$(/usr/bin/perl "$APP_SCRIPTS/transform_check.pl" --checks 'numbers bogus' "$long" "$short")" 'much shorter')"

section "the shell passes a preset's checks, and runs all of them without a preset"
nolen="$OMCTEST_WORK/nolength.json"
printf '{ "id": "x", "name": "X", "family": "gemma4it", "checks": "numbers script" }\n' > "$nolen"
out="$OMCTEST_WORK/check.out"
interp_tcall transform_check "$long" "$short" "$out" "$nolen"
check "the preset's choice is honored" "no" "$(contains "$(/bin/cat "$out")" 'much shorter')"
interp_tcall transform_check "$long" "$short" "$out"
check "without a preset every check runs" "yes" "$(contains "$(/bin/cat "$out")" 'much shorter')"
interp_tcall transform_check "$long" "$short" "$out" "$APP_RESOURCES/Transformers/10-humanize.json"
check "a preset without a checks field runs every check" "yes" "$(contains "$(/bin/cat "$out")" 'much shorter')"
# Anything but letters and spaces is stripped before it reaches the command line.
evil="$OMCTEST_WORK/evil.json"
printf '{ "id": "e", "name": "E", "family": "gemma4it", "checks": "numbers; touch /tmp/pwned" }\n' > "$evil"
interp_tcall transform_check "$long" "$short" "$out" "$evil"
check "a hostile checks string only selects known checks" "no" "$(contains "$(/bin/cat "$out")" 'much shorter')"

section "a published job records its preset, for the check that runs when it finishes"
reset_document
/bin/mkdir -p "$(spool_dir)"
printf 'Some text.' | interp_tcall publish_transform_job "$(spool_dir)" "$APP_RESOURCES/Transformers/10-humanize.json"
check "the job's preset is recorded" "$APP_RESOURCES/Transformers/10-humanize.json" "$(spool_file job.preset)"

section "the transform chooser's info sheet credits Google and Apache 2.0 for Gemma 4"
reset_document
omc_control_defaults models.window
omc_run interp.tmodels.init
/bin/mkdir -p "$(transform_cache_dir)"
printf 'best\tgemma4it\tggml-org\tgemma-4-12B-it-8bit\tGemma 4 12B (8-bit)\t12669646976\t0\tGeneral.\n' \
    > "$(transform_cache_dir)/curated.tsv"
omc_trigger 2016
omc_run interp.models.info
info_md="$(ui_value 4010)"
check "the maker is Google" "yes" "$(contains "$info_md" "Created by Google (Gemma 4 12B instruct).")"
check "it is a GGUF build" "yes" "$(contains "$info_md" "GGUF build")"
check "from the real repo" "yes" "$(contains "$info_md" "ggml-org/gemma-4-12B-it-GGUF")"
check "under Apache 2.0" "yes" "$(contains "$info_md" "Apache License")"
check "not the Gemma Terms of Use" "no" "$(contains "$info_md" "Gemma Terms of Use")"

section "Summarize runs on Gemma 4, in one pass up to the chunk budget, and checks only for numbers it added"
sp="$PRESETS/70-summarize.json"
check "it is a Gemma 4 preset" "gemma4it" "$(/usr/bin/plutil -extract family raw -o - "$sp")"
check "it is the last transform in the picker" "70-summarize.json" \
    "$(for f in "$PRESETS"/*.json; do /usr/bin/basename "$f"; done | /usr/bin/tail -1)"
# A text up to the chunk budget is summarized in one pass: the budget, the instructions and the
# longest answer must all fit in the server's context, or an ordinary article would be cut in two.
budget="$(/usr/bin/plutil -extract job.budget_tokens raw -o - "$sp")"
ctx="$(/usr/bin/plutil -extract server.ctx_size raw -o - "$sp")"
maxnew="$(/usr/bin/plutil -extract sampling.max_new_tokens raw -o - "$sp")"
check "the whole text, the instructions and the answer fit in the context" "yes" \
    "$([ $((budget + maxnew + 1000)) -le "$ctx" ] && echo yes || echo no)"
check "the budget is far above an ordinary article" "yes" "$([ "$budget" -ge 8000 ] && echo yes || echo no)"
check "it is told to use only what the text says" "yes" \
    "$(contains "$(/usr/bin/plutil -extract job.messages.0.content raw -o - "$sp")" 'Use only what the text says')"
check "and to write in the language of the text" "yes" \
    "$(contains "$(/usr/bin/plutil -extract job.messages.0.content raw -o - "$sp")" 'same language as the text')"
check "its checks leave out missing numbers and length" "added-numbers script language" \
    "$(/usr/bin/plutil -extract checks raw -o - "$sp")"
check "its status line says summarizing" "Summarizing summarized" \
    "$(interp_tcall transform_status_working "$sp") $(interp_tcall transform_status_done "$sp")"
check "a preset without status words rewrites" "Rewriting rewritten" \
    "$(interp_tcall transform_status_working "$PRESETS/20-fix-grammar.json") $(interp_tcall transform_status_done "$PRESETS/20-fix-grammar.json")"
check "the output is named a summary" "summary" "$(interp_tcall transform_output_suffix "$sp")"

section "added-numbers reports a number the summary invented, never one it left out"
# From the spike: a summary that turned train "TLK 31101" into 31100, and one that drops most of
# the article's numbers, as a summary should.
article="$(make_text_file s.src 'On 3 March 2012 at 20:57 train TLK 31101 collided with train 1322. Of the 450 firefighters and 300 police officers at the scene, 16 people died.')"
fine="$(make_text_file s.fine 'Two trains collided on 3 March 2012, killing 16 people.')"
wrong="$(make_text_file s.wrong 'Two trains, including TLK 31100, collided on 3 March 2012, killing 16 people.')"
check "dropped numbers are not reported" "" \
    "$(/usr/bin/perl "$APP_SCRIPTS/transform_check.pl" --checks 'added-numbers' "$article" "$fine")"
check "an invented number is" "Check: 1 number is not in the original: 31100." \
    "$(/usr/bin/perl "$APP_SCRIPTS/transform_check.pl" --checks 'added-numbers' "$article" "$wrong")"
check "numbers still checks both ways" "yes" \
    "$(contains "$(/usr/bin/perl "$APP_SCRIPTS/transform_check.pl" --checks 'numbers' "$article" "$fine")" 'missing')"
# The shell passes the preset's list on: the hyphen in added-numbers must survive the way there.
(
    INTERP_LANGID_BIN="$OMCTEST_WORK/no-such-langid"; export INTERP_LANGID_BIN
    interp_tcall transform_check "$article" "$fine" "$OMCTEST_WORK/s.check1" "$sp"
    interp_tcall transform_check "$article" "$wrong" "$OMCTEST_WORK/s.check2" "$sp"
)
check "through the app, a fair summary passes" "" "$(/bin/cat "$OMCTEST_WORK/s.check1")"
check "and an invented number is caught" "Check: 1 number is not in the original: 31100." "$(/bin/cat "$OMCTEST_WORK/s.check2")"

section "Summarize says so on the status line"
reset_document
make_transform_model gemma-4-12B-it-8bit >/dev/null
pref_set TransformPreset summarize
omc_control_defaults transform.window
omc_run interp.transform.init
check "the window opens on Summarize" "$sp" "$(spool_file preset.file)"
check "the button says Summarize" "Summarize" "$(ui_prop "$TRANSLATE_BTN" title)"
omc_control "$SRC_EDITOR" "A long article about a train crash."
omc_run interp.transform.run
check "the status line says Summarizing" "Summarizing..." "$(ui_value "$STATUS_TEXT")"
check "the whole text goes as one chunk budget" "12000" "$(job_field budget_tokens)"
check "the job carries the reduce template" "{{chunk}}" \
    "$(/usr/bin/plutil -extract reduce.messages.1.content raw -o - "$(spool_dir)/job.json" 2>/dev/null)"

section "a text longer than one pass is summarized in parts, then the part summaries are summarized"
# The broker (mlx-agent map) runs the reduce template on a text that fits in one chunk, and the job's
# own template on each part of a longer one, then reduce on the joined part summaries. Both carry
# the same instructions: a part summary is a summary of that part, and a broker too old to know
# "reduce" ignores it and still summarizes - one pass, as before.
check "the reduce template is chat turns" "system user" \
    "$(/usr/bin/plutil -extract job.reduce.messages.0.role raw -o - "$sp") $(/usr/bin/plutil -extract job.reduce.messages.1.role raw -o - "$sp")"
check "with the text in the user turn" "{{chunk}}" "$(/usr/bin/plutil -extract job.reduce.messages.1.content raw -o - "$sp")"
check "and the same instructions as each part gets" \
    "$(/usr/bin/plutil -extract job.messages.0.content raw -o - "$sp")" \
    "$(/usr/bin/plutil -extract job.reduce.messages.0.content raw -o - "$sp")"
check "reduce needs stitch output" "stitch" "$(/usr/bin/plutil -extract job.output raw -o - "$sp")"
check "no other preset reduces" "70-summarize.json" \
    "$(for f in "$PRESETS"/*.json; do /usr/bin/plutil -extract job.reduce json -o - "$f" >/dev/null 2>&1 && /usr/bin/basename "$f"; done)"

reset_document
omctest_end
