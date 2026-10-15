# interp.transform.init - fired when a Text Transform window loads. Fills the Transform (preset)
# picker, takes over selected text from the "Rewrite with Interpreter" service, and spawns the UI
# poller in transform mode. As in the translator, the poller owns the broker: it lists the
# installed models of the transform's families, spawns llama-server + map with the preset's
# settings, and reflects status and results.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.transform.sh"

spool=$(spool_dir_for "$window_uuid")
/bin/mkdir -p "$spool" "$TRANSFORMS_DIR"

disable_ctrl "$TRANSLATE_BTN"
disable_ctrl "$STOP_BTN"
set_status "Starting..."

populate_preset_picker "$spool"

# Selected-text handoff from the text service, consumed once (same protocol as the translator).
svc_text="$(pb_get "$PB_SERVICE_TRANSFORM_TEXT")"
pb_set "$PB_SERVICE_TRANSFORM_TEXT" ""
if [ -n "$svc_text" ] && [ -f "$svc_text" ]; then
    /bin/cat "$svc_text" | "$dialog" "$window_uuid" "$SRC_EDITOR" omc_set_value_from_stdin plain
    /bin/rm -f "$svc_text"
fi

/bin/sh "$POLL_SCRIPT" "$window_uuid" "$spool" transform \
    < /dev/null > "$spool/poll.log" 2>&1 &

# Nothing installed for the selected preset yet: open the transform model chooser over the window.
preset="$(/bin/cat "$spool/preset.file" 2>/dev/null)"
installed="$(list_preset_model_dirs "$preset")"
if [ -z "$installed" ]; then
    "$next_command" "$OMC_CURRENT_COMMAND_GUID" "interp.tmodels"
fi

exit 0
