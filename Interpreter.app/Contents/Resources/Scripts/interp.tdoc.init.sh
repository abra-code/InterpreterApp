# interp.tdoc.init - fired when a Text Transform document window loads. The transform twin of
# interp.doc.init: takes the input path from its own handoff key, previews the original on the
# left, fills the Transform picker (which names the output after the preset -
# "report-humanized.txt" next to the original, see apply_preset), and spawns the UI poller in
# transform-doc mode, which owns the broker and writes the finished result to the output file.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.transform.sh"

inp="$(pb_get "$PB_TDOC_INPUT")"
pb_set "$PB_TDOC_INPUT" ""      # consume the handoff so a later open cannot reuse it

spool=$(spool_dir_for "$window_uuid")
/bin/mkdir -p "$spool" "$TRANSFORMS_DIR"
# Written before the picker is filled: apply_preset reads it to know the output follows the preset.
/usr/bin/printf 'transform-doc' > "$spool/mode"

disable_ctrl "$TRANSLATE_BTN"
disable_ctrl "$STOP_BTN"
set_status "Starting..."

# The input path is recorded BEFORE the picker is filled, so applying the preset can name the
# output after it.
if [ -n "$inp" ] && [ -e "$inp" ]; then
    /usr/bin/printf '%s' "$inp" > "$spool/input.path"
    "$dialog" "$window_uuid" "$INPUT_PATH_TEXT" "$inp"
    "$dialog" "$window_uuid" "$QL_INPUT" "$inp"
fi
populate_preset_picker "$spool"
[ -f "$spool/input.path" ] || set_status "No input document."

/bin/sh "$POLL_SCRIPT" "$window_uuid" "$spool" transform-doc \
    < /dev/null > "$spool/poll.log" 2>&1 &

preset="$(/bin/cat "$spool/preset.file" 2>/dev/null)"
installed="$(list_transform_dirs "$(preset_get "$preset" family)")"
if [ -z "$installed" ]; then
    "$next_command" "$OMC_CURRENT_COMMAND_GUID" "interp.tmodels"
fi

exit 0
