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
disable_ctrl "$CLEAR_BTN"
disable_ctrl "$SWAP_BTN"
enable_ctrl "$STOP_BTN"

# Resolve picker indices (1-based) to language codes via the ordered code file. A stale/bogus
# index that resolves to nothing is surfaced, not silently dropped.
case "$from_idx" in ''|*[!0-9]*) from_idx="" ;; esac
case "$to_idx" in ''|*[!0-9]*) to_idx="" ;; esac
src_code=""
tgt_code=""
[ -n "$from_idx" ] && src_code=$(/usr/bin/sed -n "${from_idx}p" "$spool/langcodes")
[ -n "$to_idx" ] && tgt_code=$(/usr/bin/sed -n "${to_idx}p" "$spool/langcodes")
if [ -z "$src_code" ] || [ -z "$tgt_code" ]; then
    enable_ctrl "$TRANSLATE_BTN"; enable_ctrl "$CLEAR_BTN"; enable_ctrl "$SWAP_BTN"
    disable_ctrl "$STOP_BTN"
    set_status "Please choose valid From and To languages."
    exit 0
fi

# Character counter (on translate only; no per-keystroke handler in v1). wc -m under a UTF-8
# locale counts characters regardless of the ambient LANG.
nchars=$(/usr/bin/printf '%s' "$src" | LC_ALL=en_US.UTF-8 /usr/bin/wc -m | /usr/bin/tr -d ' ')
"$dialog" "$window_uuid" "$CHAR_TEXT" "$nchars characters"

# Bump the epoch (a new job is a higher epoch); safe under the dispatch lock.
epoch=$(pb_get "interp_epoch_${window_uuid}")
case "$epoch" in ''|*[!0-9]*) epoch=0 ;; esac
epoch=$((epoch + 1))
pb_set "interp_epoch_${window_uuid}" "$epoch"

# Source text -> per-epoch file (printf %s never interprets the content), so a rapid re-dispatch
# can never pair one job's text with another job's language metadata.
srcfile="source.${epoch}.txt"
/usr/bin/printf '%s' "$src" > "$spool/$srcfile"

# Build job.json (all values fixed/safe: numbers, language codes, the {{chunk}} placeholder)
# and publish it atomically. output=stitch reassembles the per-chunk translations into one
# document; the model's own template turns the structured content into the translation prompt.
/bin/cat > "$spool/job.json.tmp" <<EOF
{"epoch":$epoch,"output":"stitch","budget_tokens":$BUDGET_TOKENS,"text_file":"$srcfile","messages":[{"role":"user","content":[{"type":"text","source_lang_code":"$src_code","target_lang_code":"$tgt_code","text":"{{chunk}}"}]}]}
EOF
/bin/mv "$spool/job.json.tmp" "$spool/job.json"

set_status "Translating…"

exit 0
