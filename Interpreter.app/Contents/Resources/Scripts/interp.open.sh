# interp.open - File > Open. Runs after the CHOOSE_FILE_DIALOG (filtered to textutil-supported
# document types) has set OMC_DLG_CHOOSE_FILE_PATH. Hands the chosen path to the document window's
# init via a private pasteboard key, then opens that window. Cancelling the panel leaves the path
# empty, so we quietly do nothing.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"

sel="$OMC_DLG_CHOOSE_FILE_PATH"
[ -n "$sel" ] && [ -e "$sel" ] || exit 0

route_document "$sel"

exit 0
