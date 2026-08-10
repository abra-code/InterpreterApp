#!/bin/sh
# Tests/20-languages.test.sh - the language layer, and the family-specific job
# each model gets.
#
# Two things here are quietly destructive when wrong. A picker delivers a
# 1-based POSITION in a list that is filtered per model family, so the same
# index means different languages under different models - which is why the
# preference is stored as a code and why a stale index must never be trusted.
# And each family is prompted differently: MiLMMT-46 ships no chat template and
# is prompted as a raw completion with ENGLISH LANGUAGE NAMES, Hy-MT2 takes a
# plain instruction naming the target, TranslateGemma takes structured content
# with CODES. Handing one family another's job does not fail - it mistranslates.
. "${OMCTEST_LIB:?set OMCTEST_LIB, or run via: appletbuilder test}"
. "$OMCTEST_TESTS/lib.test.interp.sh"

# Populate this window's pickers for a given installed model, and hand back a
# spool that is ready for a dispatch. The poller is what writes model.dir in the
# real app; writing it here is standing in for the poller having done its job.
prepare_for_model() { # <model-dir>
    reset_document
    /bin/mkdir -p "$(spool_dir)"
    printf '%s' "$1" > "$(spool_dir)/model.dir"
    interp_call populate_language_pickers "$(spool_dir)" >/dev/null 2>&1
}

# The same, but keeping the preferences and the installed models - "the user
# switched the Model picker". A section about a saved language surviving a model
# switch has to use this: prepare_for_model resets the preferences, which is the
# very thing such a section means to assert was not touched.
switch_model() { # <model-dir>
    reset_window
    /bin/mkdir -p "$(spool_dir)"
    printf '%s' "$1" > "$(spool_dir)/model.dir"
    interp_call populate_language_pickers "$(spool_dir)" >/dev/null 2>&1
}

section "the shipped language list is the source of truth"
reset_document
/bin/mkdir -p "$(spool_dir)"
interp_call populate_language_pickers "$(spool_dir)" >/dev/null 2>&1
total="$(/usr/bin/grep -c '' "$APP_RESOURCES/languages.tsv")"
check "every row became an option" "$total" "$(langcodes | /usr/bin/grep -c '')"
check "and the unfiltered list matches it" "$total" "$(langcodes_all | /usr/bin/grep -c '')"

section "a family with a language file filters the pickers to what it supports"
tg="$(make_mlx_model translategemma-12b-4bit)"
mm="$(make_mlx_model milmmt-46-12b-4bit)"
hy="$(make_gguf_model hy-mt2-7b-q4)"

prepare_for_model "$tg"
# TranslateGemma ships no languages.translategemma.tsv, so it gets everything.
check "TranslateGemma offers the full list" "$total" "$(langcodes | /usr/bin/grep -c '')"
check "recorded as its family" "translategemma" "$(langfamily)"

prepare_for_model "$mm"
milmmt_rows="$(/usr/bin/grep -vc '^[[:space:]]*#' "$APP_RESOURCES/languages.milmmt.tsv")"
check "MiLMMT-46 offers only its own languages" "$milmmt_rows" \
    "$(langcodes | /usr/bin/grep -c '')"
check "recorded as its family" "milmmt" "$(langfamily)"

prepare_for_model "$hy"
hymt_rows="$(/usr/bin/grep -vc '^[[:space:]]*#' "$APP_RESOURCES/languages.hymt.tsv")"
check "Hy-MT2 offers only its own" "$hymt_rows" "$(langcodes | /usr/bin/grep -c '')"
check "recorded as its family" "hymt" "$(langfamily)"
# The filtered list is genuinely smaller than the full one, or the check above
# would pass for a filter that does nothing.
check "which really is fewer than the full list" "yes" \
    "$([ "$hymt_rows" -lt "$total" ] && echo yes || echo no)"
# ...and the unfiltered list is still recorded in full, because the legacy
# index migration resolves against it.
check "while langcodes.all stays complete" "$total" "$(langcodes_all | /usr/bin/grep -c '')"

section "a language the family does not support is absent from its list"
check "Afrikaans is in the shipped list" "1" \
    "$(/usr/bin/grep -c $'\taf$' "$APP_RESOURCES/languages.tsv")"
check "but Hy-MT2 does not offer it" "" \
    "$(interp_call lang_code_index "$(spool_dir)" af)"
check "while it does offer German" "yes" \
    "$([ -n "$(interp_call lang_code_index "$(spool_dir)" de)" ] && echo yes || echo no)"

section "the same index means different languages under different models"
prepare_for_model "$tg"
tg_row="$(interp_call lang_code_index "$(spool_dir)" af)"
tg_code="$(interp_call resolve_lang_code "$(spool_dir)" "$tg_row")"
prepare_for_model "$hy"
hy_code="$(interp_call resolve_lang_code "$(spool_dir)" "$tg_row")"
check "row $tg_row is Afrikaans under TranslateGemma" "af" "$tg_code"
check "and something else under Hy-MT2" "no" \
    "$([ "$hy_code" = "af" ] && echo yes || echo no)"
# This is the whole reason the preference is a CODE. An index would have
# silently changed the user's language the moment they switched model.
check "which is why a preference is stored as a code, not a row" "yes" \
    "$([ -n "$hy_code" ] && echo yes || echo no)"

section "an unsupported saved language falls back without being erased"
prepare_for_model "$tg"
pref_set FromLang af
pref_set ToLang de
switch_model "$hy"
# The programmatic sets below happen inside populate's quiet window, so the
# change handlers do not persist them: switching to a family that lacks the
# saved language MASKS the preference for the session instead of erasing it.
check "the saved From is untouched in preferences" "af" "$(pref FromLang)"
from_code="$(interp_call resolve_lang_code "$(spool_dir)" "$(ui_value "$FROM_PICKER")")"
check "but the picker fell back to a supported language" "en" "$from_code"
check "and the supported To was honored" "de" \
    "$(interp_call resolve_lang_code "$(spool_dir)" "$(ui_value "$TO_PICKER")")"
# Switching back restores it, which is the point of masking rather than erasing.
switch_model "$tg"
check "switching back restores the saved language" "af" \
    "$(interp_call resolve_lang_code "$(spool_dir)" "$(ui_value "$FROM_PICKER")")"

section "a legacy index preference is migrated to a code, once"
reset_document
/bin/mkdir -p "$(spool_dir)"
# Older builds stored FromIndex/ToIndex: 1-based rows of the full sorted list,
# which is exactly what langcodes.all reproduces.
pref_set FromIndex 3
pref_set ToIndex 5
interp_call populate_language_pickers "$(spool_dir)" >/dev/null 2>&1
expected_from="$(langcodes_all | /usr/bin/sed -n 3p)"
expected_to="$(langcodes_all | /usr/bin/sed -n 5p)"
check "the From index became a code" "$expected_from" "$(pref FromLang)"
check "and the To index too"         "$expected_to"   "$(pref ToLang)"
check "the codes are real languages"  "yes" \
    "$([ -n "$expected_from" ] && [ -n "$expected_to" ] && echo yes || echo no)"

section "migration never overwrites a code that is already there"
reset_document
/bin/mkdir -p "$(spool_dir)"
pref_set FromLang ja
pref_set FromIndex 3
interp_call populate_language_pickers "$(spool_dir)" >/dev/null 2>&1
check "the existing code stands" "ja" "$(pref FromLang)"

section "a garbage legacy index is ignored rather than resolved"
reset_document
/bin/mkdir -p "$(spool_dir)"
pref_set FromIndex "not-a-number"
interp_call populate_language_pickers "$(spool_dir)" >/dev/null 2>&1
check "nothing was migrated" "" "$(pref FromLang)"
check "and the picker still landed on English" "en" \
    "$(interp_call resolve_lang_code "$(spool_dir)" "$(ui_value "$FROM_PICKER")")"

section "resolve_lang_code refuses anything that is not a row number"
prepare_for_model "$tg"
check "an empty index"       "" "$(interp_call resolve_lang_code "$(spool_dir)" "")"
check "a non-numeric index"  "" "$(interp_call resolve_lang_code "$(spool_dir)" "12x")"
check "a negative index"     "" "$(interp_call resolve_lang_code "$(spool_dir)" "-1")"
check "an out-of-range one"  "" "$(interp_call resolve_lang_code "$(spool_dir)" "99999")"
# The positive control: without it every check above would pass against a
# function that always printed nothing.
check "but a real row resolves" "en" \
    "$(interp_call resolve_lang_code "$(spool_dir)" "$(interp_call lang_code_index "$(spool_dir)" en)")"

section "a family's prompt names are its own, and are the support check"
# MiLMMT-46 was trained on plain "Portuguese" and "Norwegian", not on the
# display names "Portuguese (Brazil)" and "Norwegian Bokmal". Sending the
# display name would prompt for a language the model was never taught.
check "MiLMMT calls pt-BR plain Portuguese" "Portuguese" \
    "$(interp_call family_prompt_lang_name milmmt pt-BR)"
check "and nb plain Norwegian"              "Norwegian" \
    "$(interp_call family_prompt_lang_name milmmt nb)"
check "Hy-MT2 calls zh-Hans plain Chinese"  "Chinese" \
    "$(interp_call family_prompt_lang_name hymt zh-Hans)"
check "MiLMMT is more specific about it"    "Chinese (Simplified)" \
    "$(interp_call family_prompt_lang_name milmmt zh-Hans)"
# No row means the family does not support the language, which is what makes
# this the support check as well as the naming one.
check "an unsupported code has no name"     "" \
    "$(interp_call family_prompt_lang_name hymt af)"
check "and neither does a family with no file" "" \
    "$(interp_call family_prompt_lang_name translategemma en)"

section "TranslateGemma gets structured content keyed by CODE"
prepare_for_model "$tg"
printf 'Hello world' | interp_call publish_translation_job "$(spool_dir)" en de
check_exists "a job was published" "$(spool_dir)/job.json"
check "with the source code"  "yes" "$(job_says '"source_lang_code":"en"')"
check "and the target code"   "yes" "$(job_says '"target_lang_code":"de"')"
check "as chat messages"      "yes" "$(job_says '"messages"')"
check "with a chunk placeholder for the broker to fill" "yes" "$(job_says '{{chunk}}')"
check "the text went to a per-epoch file" "Hello world" "$(job_source_text)"
check "and the JSON references it rather than embedding it" "yes" \
    "$(job_says '"text_file":"source.1.txt"')"

section "MiLMMT-46 gets a raw completion prompt with English NAMES"
prepare_for_model "$mm"
printf 'Hello world' | interp_call publish_translation_job "$(spool_dir)" en pt-BR
# Its model card specifies this exact shape, and add_special_tokens false.
check "the prompt names both languages in English" "yes" \
    "$(job_says 'Translate this from English to Portuguese:')"
check "special tokens are off"  "yes" "$(job_says '"add_special_tokens":false')"
check "it is a prompt, not messages" "yes" "$(job_says '"prompt"')"
check "and carries no chat messages"  "no"  "$(job_says '"messages"')"
# The codes must NOT appear: this family was never trained on them.
check "no language codes leaked into the prompt" "no" "$(job_says '"source_lang_code"')"

section "Hy-MT2 gets a chat instruction naming only the target"
prepare_for_model "$hy"
printf 'Hello world' | interp_call publish_translation_job "$(spool_dir)" en zh-Hans
check "it is a chat message"  "yes" "$(job_says '"messages"')"
check "naming the target in English" "yes" \
    "$(job_says 'Translate the following text into Chinese')"
check "and asking for no commentary"  "yes" \
    "$(job_says 'without any additional explanation')"
check "no structured content"  "no" "$(job_says '"source_lang_code"')"

section "a named-language family refuses a pair it cannot name"
prepare_for_model "$hy"
/bin/rm -f "$(spool_dir)/job.json"
# Afrikaans is in the shipped list but not in Hy-MT2's. Publishing anyway would
# put a blank language name in the prompt and mistranslate rather than fail.
check "publishing is refused" "no" \
    "$(printf 'Hello' | interp_call publish_translation_job "$(spool_dir)" en af >/dev/null 2>&1 && echo yes || echo no)"
check_absent "and nothing was published" "$(spool_dir)/job.json"
# It still drains stdin, so the caller's pipe neither blocks nor takes a SIGPIPE.
check "the source text was consumed rather than left in the pipe" "no" \
    "$([ -f "$(spool_dir)/source.1.txt" ] && echo yes || echo no)"

section "a code-based family accepts a pair no name file covers"
prepare_for_model "$tg"
check "publishing succeeds" "yes" \
    "$(printf 'Hello' | interp_call publish_translation_job "$(spool_dir)" en af >/dev/null 2>&1 && echo yes || echo no)"
check "and the codes went through verbatim" "yes" "$(job_says '"target_lang_code":"af"')"

section "an unknown model family is treated as TranslateGemma-shaped"
generic="$(make_mlx_model some-other-model-4b)"
prepare_for_model "$generic"
check "its family is generic" "generic" "$(interp_call model_family_of "$generic")"
printf 'Hello' | interp_call publish_translation_job "$(spool_dir)" en de
# Stated as a deliberate default rather than an accident: a NEW raw-prompt
# family has to be added to model_family_of and branched in
# publish_translation_job, or it silently gets this chat-messages job.
check "so it gets structured content" "yes" "$(job_says '"source_lang_code":"en"')"

section "each dispatch gets its own epoch and its own source file"
prepare_for_model "$tg"
printf 'first' | interp_call publish_translation_job "$(spool_dir)" en de
check "the first epoch is 1" "1" "$(job_field epoch)"
printf 'second' | interp_call publish_translation_job "$(spool_dir)" en de
check "the second is 2"      "2" "$(job_field epoch)"
check "the first text is still where it was" "first"  "$(spool_file source.1.txt)"
check "and the second is its own"            "second" "$(spool_file source.2.txt)"
check "the job points at the newer one"      "second" "$(job_source_text)"

section "source text with quotes and newlines cannot break the job"
prepare_for_model "$tg"
tricky='He said "hi",
and \ then left'
printf '%s' "$tricky" | interp_call publish_translation_job "$(spool_dir)" en de
check "the text survived verbatim" "$tricky" "$(job_source_text)"
# The JSON only ever carries fixed values, which is exactly why the text is
# referenced by file rather than embedded.
check "and the JSON is a single line of fixed values" "1" \
    "$(job_json | /usr/bin/grep -c '')"

section "a fresh dispatch drops the previous result and timing"
prepare_for_model "$tg"
printf 'x' | interp_call publish_translation_job "$(spool_dir)" en de
printf 'stale output' > "$(spool_dir)/result.txt"
printf '12.5' > "$(spool_dir)/translate.elapsed"
printf 'y' | interp_call publish_translation_job "$(spool_dir)" en de
# The poller re-pushes output only once the broker writes a fresh result, so a
# stale one left here would be shown as this job's translation.
check_absent "the stale result is gone"  "$(spool_dir)/result.txt"
check_absent "and the stale timing too"  "$(spool_dir)/translate.elapsed"
check "a new dispatch time was stamped" "yes" \
    "$([ -s "$(spool_dir)/translate.start" ] && echo yes || echo no)"

section "the job is published atomically"
prepare_for_model "$tg"
printf 'x' | interp_call publish_translation_job "$(spool_dir)" en de
# It is written to job.json.tmp and moved into place, so the broker never reads
# a half-written job.
check_absent "no temporary was left behind" "$(spool_dir)/job.json.tmp"
check_exists "and the job is there"         "$(spool_dir)/job.json"

section "cumulative: no handler wrote to a view id the window does not declare"
check "no undeclared ids" "" "$(ui_unknown_writes)"
check "the harness detected no misuse" "" "$(ui_errors)"

omctest_end
