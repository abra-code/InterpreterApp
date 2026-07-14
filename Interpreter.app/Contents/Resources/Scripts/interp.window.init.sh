# interp.window.init - fired when the translator window loads. Populates the language pickers
# from languages.tsv and spawns the UI poller. The poller (not this script) owns the mlx-agent
# map broker: it discovers the installed model, spawns/loads it, keeps the Model picker in sync
# with what is installed, and reflects loading/ready/translating status into the UI. Spawning
# the broker from the poller (single owner) is what makes first-run auto-pickup and in-dialog
# model switching work without this init script knowing about either.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"

spool=$(spool_dir_for "$window_uuid")
/bin/mkdir -p "$spool" "$MODELS_DIR"

# Action controls stay disabled until the poller sees the model reach "ready".
disable_ctrl "$TRANSLATE_BTN"
disable_ctrl "$SWAP_BTN"
disable_ctrl "$STOP_BTN"
set_status "Starting…"

# --- populate the language pickers from languages.tsv -----------------------
# Build a JSON array of display names and a parallel ordered code file (langcodes), so a
# handler can map a picker's 1-based index -> language code. Display names in the shipped TSV
# contain no quotes/backslashes, so hand-building the JSON array is safe.
#
# The pickers are sorted alphabetically by display name (case-insensitive) rather than shown in
# the TSV's authoring order. We sort a copy into a temp file first (not a "sort | while" pipe)
# so the loop runs in this shell and $opts survives it; sorting by the leading name field is
# safe because names contain no tabs.
tab=$(/usr/bin/printf '\t')
sorted_langs="$spool/languages.sorted.tsv"
LC_ALL=C /usr/bin/sort -f "$RESOURCES_DIR/languages.tsv" > "$sorted_langs"
/bin/rm -f "$spool/langcodes"
opts="["
first=1
while IFS="$tab" read -r name code; do
    [ -n "$name" ] || continue
    [ -n "$code" ] || continue
    if [ "$first" = 1 ]; then first=0; else opts="$opts,"; fi
    opts="$opts\"$name\""
    /usr/bin/printf '%s\n' "$code" >> "$spool/langcodes"
done < "$sorted_langs"
opts="$opts]"

"$dialog" "$window_uuid" "$FROM_PICKER" omc_set_property "options" "$opts"
"$dialog" "$window_uuid" "$TO_PICKER" omc_set_property "options" "$opts"

# Restore saved language selection (1-based indices), defaulting to English -> Spanish and
# clamping to the current option count (a stale index from an older, longer list would
# otherwise resolve to no language and make Translate silently refuse). Because the list is now
# sorted by name, the default indices are looked up from langcodes by code (en/es) rather than
# assumed to be 1 and 2. code_index() returns the 1-based row of a code, or empty if absent.
code_index() {
    local _code="$1"
    /usr/bin/grep -n "^${_code}\$" "$spool/langcodes" 2>/dev/null | /usr/bin/head -1 | /usr/bin/cut -d: -f1
}
nlangs=$(/usr/bin/wc -l < "$spool/langcodes" | /usr/bin/tr -d ' ')
[ -n "$nlangs" ] && [ "$nlangs" -ge 1 ] 2>/dev/null || nlangs=1
default_from=$(code_index en); case "$default_from" in ''|*[!0-9]*) default_from=1 ;; esac
default_to=$(code_index es);   case "$default_to"   in ''|*[!0-9]*) default_to=$default_from ;; esac
saved_from=$(/usr/bin/defaults read "$BUNDLE_ID" FromIndex 2>/dev/null)
saved_to=$(/usr/bin/defaults read "$BUNDLE_ID" ToIndex 2>/dev/null)
case "$saved_from" in ''|*[!0-9]*) saved_from=$default_from ;; esac
case "$saved_to" in ''|*[!0-9]*) saved_to=$default_to ;; esac
[ "$saved_from" -ge 1 ] && [ "$saved_from" -le "$nlangs" ] 2>/dev/null || saved_from=$default_from
[ "$saved_to" -ge 1 ] && [ "$saved_to" -le "$nlangs" ] 2>/dev/null || saved_to=$default_to
"$dialog" "$window_uuid" "$FROM_PICKER" "$saved_from"
"$dialog" "$window_uuid" "$TO_PICKER" "$saved_to"

# --- spawn the UI poller (which owns the broker) ----------------------------
/bin/sh "$SCRIPTS_DIR/interp.poll.sh" "$window_uuid" "$spool" \
    < /dev/null > "$spool/poll.log" 2>&1 &

# First run (no model installed yet): open the model chooser over the translator so the user
# can download one. The poller keeps the translator's status/picker in sync meanwhile.
if ! resolve_model_dir >/dev/null 2>&1; then
    "$next_command" "$OMC_CURRENT_COMMAND_GUID" "interp.models"
fi

exit 0
