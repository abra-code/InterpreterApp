# interp.translate - compose a translation job and drop it into the spool. The map broker
# picks it up; the poller reflects progress and results back into the UI. The source text is
# written to a per-epoch file (via printf, safe for arbitrary content) and referenced from
# job.json, so the JSON itself carries only fixed, safe values.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"

src="$OMC_ACTIONUI_VIEW_100_VALUE"
from_idx="$OMC_ACTIONUI_VIEW_20_VALUE"
to_idx="$OMC_ACTIONUI_VIEW_21_VALUE"

# Nothing to translate.
[ -n "$src" ] || exit 0

spool=$(spool_dir_for "$window_uuid")
[ -d "$spool" ] || exit 0

# Re-entry guard: the button and its Cmd+Return shortcut are two trigger paths, and disabling
# the button is async. An atomic mkdir lock serializes dispatch so the epoch read-modify-write
# and the job publish cannot interleave. Released on any exit.
/bin/mkdir "$spool/dispatch.lock" 2>/dev/null || exit 0
trap '/bin/rmdir "$spool/dispatch.lock" 2>/dev/null' EXIT

# Snappy UI transition (the poller also does this once it observes "mapping").
disable_ctrl "$TRANSLATE_BTN"
disable_ctrl "$SWAP_BTN"
enable_ctrl "$STOP_BTN"

# Resolve picker indices (1-based) to language codes via the ordered code file. A stale/bogus
# index that resolves to nothing is surfaced, not silently dropped.
src_code=$(resolve_lang_code "$spool" "$from_idx")
tgt_code=$(resolve_lang_code "$spool" "$to_idx")
if [ -z "$src_code" ] || [ -z "$tgt_code" ]; then
    enable_ctrl "$TRANSLATE_BTN"; enable_ctrl "$SWAP_BTN"
    disable_ctrl "$STOP_BTN"
    set_status "Please choose valid From and To languages."
    exit 0
fi

# Character counter (on translate only; no per-keystroke handler in v1). wc -m under a UTF-8
# locale counts characters regardless of the ambient LANG.
nchars=$(/usr/bin/printf '%s' "$src" | LC_ALL=en_US.UTF-8 /usr/bin/wc -m | /usr/bin/tr -d ' ')
"$dialog" "$window_uuid" "$CHAR_TEXT" "$nchars characters"

# Erase the previous translation from the target pane immediately (a new job starts now). The
# shared dispatch also drops stale result.txt so the poller re-pushes only once the broker writes
# fresh output; clearing the editor here is why the app needs no explicit Clear button.
/usr/bin/printf '' | "$dialog" "$window_uuid" "$TGT_EDITOR" omc_set_value_from_stdin plain

# Publish the job from the editor's text (shared with the document window): bumps the epoch, writes
# the per-epoch source file, builds+publishes job.json, and stamps the dispatch time for timing.
# Publishing can refuse (a raw-prompt family whose language names cannot be resolved) - restore
# the UI and say so instead of leaving a silent dead Translate.
/usr/bin/printf '%s' "$src" | publish_translation_job "$spool" "$src_code" "$tgt_code"
if [ $? -ne 0 ]; then
    enable_ctrl "$TRANSLATE_BTN"; enable_ctrl "$SWAP_BTN"
    disable_ctrl "$STOP_BTN"
    set_status "Could not prepare the translation for this model and language pair."
    exit 0
fi

set_status "Translating…"

exit 0
