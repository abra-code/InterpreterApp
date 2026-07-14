# interp.service.text - "Translate with Interpreter" service on selected text. macOS hands the
# selection in OMC_OBJ_TEXT. We stash it in a temp file (environment variables are size-limited;
# a large selection would be truncated or rejected) and pass the path to the text window via a
# private pasteboard key, then open that window. interp.window.init loads the text into the left
# editor and deletes the temp file. An empty selection just opens an empty translator window.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"

if [ -n "$OMC_OBJ_TEXT" ]; then
    tmpf="$(/usr/bin/mktemp -t interp_service_text 2>/dev/null)" || tmpf=""
    if [ -n "$tmpf" ]; then
        /usr/bin/printf '%s' "$OMC_OBJ_TEXT" > "$tmpf"
        pb_set "INTERP_SERVICE_TEXT_FILE" "$tmpf"
    fi
fi

"$next_command" "$OMC_CURRENT_COMMAND_GUID" "interp.new"

exit 0
