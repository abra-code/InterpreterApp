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

# --- spawn the UI poller (which owns the broker) ----------------------------
/bin/sh "$SCRIPTS_DIR/interp.poll.sh" "$window_uuid" "$spool" \
    < /dev/null > "$spool/poll.log" 2>&1 &

# First run (no model installed yet): open the model chooser over the translator so the user
# can download one. The poller keeps the translator's status/picker in sync meanwhile.
if ! resolve_model_dir >/dev/null 2>&1; then
    "$next_command" "$OMC_CURRENT_COMMAND_GUID" "interp.models"
fi

exit 0
