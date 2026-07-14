# Interpreter.main - launch/drop dispatcher. OMC runs this main command both on a bare launch
# (OMC_OBJ_PATH empty) and when documents are dropped on the app or opened via "Open With"
# (OMC_OBJ_PATH = newline-separated dropped paths). It opens no window itself; it routes:
#   - a dropped document  -> the document-translation window (interp.doc), via the same private
#     pasteboard handoff that File > Open uses;
#   - a bare launch       -> the two-editor text window (interp.new).
# We translate one document at a time, so only the first dropped path is used.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"

first="$(/usr/bin/printf '%s' "$OMC_OBJ_PATH" | /usr/bin/sed -n '1p')"

if [ -n "$first" ] && [ -f "$first" ]; then
    route_document "$first"
else
    "$next_command" "$OMC_CURRENT_COMMAND_GUID" "interp.new"
fi

exit 0
