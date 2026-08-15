# interp.doc.init - fired when the document-translation window loads. Reads the input path handed
# off by interp.open (private pasteboard), previews the original document on the left, populates
# the language pickers, computes the output path for the To language, and spawns the shared UI
# poller in "doc" mode. As in the text window, the poller (single owner) discovers/loads the
# model, keeps the Model picker in sync, and reflects status; on completion it writes the
# translation to the output file and points the right-hand QuickLook at it.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"

inp="$(pb_get "$PB_DOC_INPUT")"
pb_set "$PB_DOC_INPUT" ""      # consume the handoff so a later open cannot reuse it

spool=$(spool_dir_for "$window_uuid")
/bin/mkdir -p "$spool" "$MODELS_DIR"
/usr/bin/printf 'doc' > "$spool/mode"

# Action controls stay disabled until the poller sees the model reach "ready".
disable_ctrl "$TRANSLATE_BTN"
disable_ctrl "$STOP_BTN"
set_status "Starting…"

# Sorted-by-name language pickers + parallel langcodes file (shared with the text window).
populate_language_pickers "$spool"

# Input document: preview the original (formatted) on the left and remember its path for dispatch.
# Default output = "<name>-<to-language>.txt" next to the original, made unique so nothing is
# clobbered; it is re-derived whenever the To picker changes, so the file is always named after the
# language it holds.
if [ -n "$inp" ] && [ -e "$inp" ]; then
    /usr/bin/printf '%s' "$inp" > "$spool/input.path"
    "$dialog" "$window_uuid" "$INPUT_PATH_TEXT" "$inp"
    "$dialog" "$window_uuid" "$QL_INPUT" "$inp"

    refresh_doc_output "$spool" "$(/bin/cat "$spool/to.code" 2>/dev/null)"
else
    set_status "No input document."
fi

# --- spawn the UI poller (which owns the broker), in doc mode ---------------
/bin/sh "$POLL_SCRIPT" "$window_uuid" "$spool" doc \
    < /dev/null > "$spool/poll.log" 2>&1 &

# First run (no model installed yet): open the model chooser over this window so the user can
# download one. The poller keeps this window's status/picker in sync meanwhile.
model_dir=$(resolve_model_dir 2>/dev/null)
if [ -z "$model_dir" ]; then
    "$next_command" "$OMC_CURRENT_COMMAND_GUID" "interp.models"
fi

exit 0
