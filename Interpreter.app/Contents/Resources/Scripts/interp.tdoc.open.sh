# interp.tdoc.open - File > Open for Text Transform. Runs after the CHOOSE_FILE_DIALOG (filtered to
# the document types the converter reads) has set OMC_DLG_CHOOSE_FILE_PATH, and opens the Text
# Transform document window on the chosen file. Cancelling the panel leaves the path empty.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"

sel="$OMC_DLG_CHOOSE_FILE_PATH"
[ -n "$sel" ] && [ -e "$sel" ] || exit 0

route_transform_document "$sel"

exit 0
