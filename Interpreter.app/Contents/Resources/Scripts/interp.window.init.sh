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
# Sorted-by-name option build + parallel langcodes file + saved-selection restore, shared with
# the document window (see lib.interp.sh).
populate_language_pickers "$spool"

# --- selected-text handoff from the "Translate with Interpreter" service -----
# interp.service.text stashes the selection in a temp file and points this key at it. Load it into
# the left editor once, then consume the key and remove the file so a later File > New opens empty.
_svc_text="$(pb_get "$PB_SERVICE_TEXT")"
pb_set "$PB_SERVICE_TEXT" ""      # consume the handoff first, so a failed/duplicate open cannot re-inject it
if [ -n "$_svc_text" ] && [ -f "$_svc_text" ]; then
    /bin/cat "$_svc_text" | "$dialog" "$window_uuid" "$SRC_EDITOR" omc_set_value_from_stdin plain
    /bin/rm -f "$_svc_text"
fi

# --- spawn the UI poller (which owns the broker) ----------------------------
/bin/sh "$POLL_SCRIPT" "$window_uuid" "$spool" \
    < /dev/null > "$spool/poll.log" 2>&1 &

# First run (no model installed yet): open the model chooser over the translator so the user
# can download one. The poller keeps the translator's status/picker in sync meanwhile.
model_dir=$(resolve_model_dir 2>/dev/null)
if [ -z "$model_dir" ]; then
    "$next_command" "$OMC_CURRENT_COMMAND_GUID" "interp.models"
fi

exit 0
