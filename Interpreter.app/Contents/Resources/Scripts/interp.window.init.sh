# interp.window.init - fired when the translator window loads. Populates the language
# pickers from languages.tsv, spawns the long-lived mlx-agent map broker and a UI poller,
# and sets the initial control state. The poller (not this script) reflects the model's
# loading/ready/translating status into the UI.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"

spool=$(spool_dir_for "$window_uuid")
/bin/mkdir -p "$spool"

# Translate / Clear / Swap stay disabled until the poller sees the model reach "ready".
disable_ctrl "$TRANSLATE_BTN"
disable_ctrl "$CLEAR_BTN"
disable_ctrl "$SWAP_BTN"
disable_ctrl "$STOP_BTN"

# --- populate the language pickers from languages.tsv -----------------------
# Build a JSON array of display names and a parallel ordered code file (langcodes), so a
# handler can map a picker's 1-based index -> language code. Display names in the shipped TSV
# contain no quotes/backslashes, so hand-building the JSON array is safe.
tab=$(/usr/bin/printf '\t')
/bin/rm -f "$spool/langcodes"
opts="["
first=1
while IFS="$tab" read -r name code; do
    [ -n "$name" ] || continue
    [ -n "$code" ] || continue
    if [ "$first" = 1 ]; then first=0; else opts="$opts,"; fi
    opts="$opts\"$name\""
    /usr/bin/printf '%s\n' "$code" >> "$spool/langcodes"
done < "$RESOURCES_DIR/languages.tsv"
opts="$opts]"

"$dialog" "$window_uuid" "$FROM_PICKER" omc_set_property "options" "$opts"
"$dialog" "$window_uuid" "$TO_PICKER" omc_set_property "options" "$opts"

# Restore saved language selection (1-based indices), defaulting to English -> Spanish and
# clamping to the current option count (a stale index from an older, longer list would
# otherwise resolve to no language and make Translate silently refuse).
nlangs=$(/usr/bin/wc -l < "$spool/langcodes" | /usr/bin/tr -d ' ')
[ -n "$nlangs" ] && [ "$nlangs" -ge 1 ] 2>/dev/null || nlangs=1
saved_from=$(/usr/bin/defaults read "$BUNDLE_ID" FromIndex 2>/dev/null)
saved_to=$(/usr/bin/defaults read "$BUNDLE_ID" ToIndex 2>/dev/null)
case "$saved_from" in ''|*[!0-9]*) saved_from=1 ;; esac
case "$saved_to" in ''|*[!0-9]*) saved_to=2 ;; esac
[ "$saved_from" -ge 1 ] && [ "$saved_from" -le "$nlangs" ] 2>/dev/null || saved_from=1
[ "$saved_to" -ge 1 ] && [ "$saved_to" -le "$nlangs" ] 2>/dev/null || saved_to=2
"$dialog" "$window_uuid" "$FROM_PICKER" "$saved_from"
"$dialog" "$window_uuid" "$TO_PICKER" "$saved_to"

# --- resolve the model and spawn the broker + poller ------------------------
model=$(resolve_model_dir)
if [ -z "$model" ]; then
    set_status "No translation model found. Place one under $MODELS_DIR."
    exit 0
fi
pb_set "interp_model_${window_uuid}" "$model"
pb_set "interp_epoch_${window_uuid}" "0"

# Long-lived map broker: loads the model once, serves translation jobs from the spool. Spawned
# backgrounded with /dev/null stdin (it does NOT treat that as parent-death); it exits when the
# spool directory disappears (window close / app quit) or when reaped at terminate.
"$AGENT_BIN" map --model "$model" --spool "$spool" \
    --extra-eos-token "$EXTRA_EOS" --temperature "$GEN_TEMP" --max-new-tokens "$GEN_MAXTOK" \
    < /dev/null > "$spool/agent.log" 2>&1 &

# UI poller: reflects status.json / result.txt into the window for the window's lifetime.
label=$(model_label_for "$model")
/bin/sh "$SCRIPTS_DIR/interp.poll.sh" "$window_uuid" "$spool" "$label" \
    < /dev/null > "$spool/poll.log" 2>&1 &

exit 0
