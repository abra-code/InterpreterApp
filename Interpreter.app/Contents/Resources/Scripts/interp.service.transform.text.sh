# interp.service.transform.text - "Rewrite with Interpreter" service on selected text. Same handoff
# as interp.service.text (temp file + private pasteboard key, consumed by the window's init), but
# opens a Text Transform window. An empty selection opens an empty window.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"

if [ -n "$OMC_OBJ_TEXT" ]; then
    tmpf="$(/usr/bin/mktemp -t interp_service_transform 2>/dev/null)" || tmpf=""
    if [ -n "$tmpf" ]; then
        /usr/bin/printf '%s' "$OMC_OBJ_TEXT" > "$tmpf"
        pb_set "$PB_SERVICE_TRANSFORM_TEXT" "$tmpf"
    fi
fi

"$next_command" "$OMC_CURRENT_COMMAND_GUID" "interp.transform"

exit 0
