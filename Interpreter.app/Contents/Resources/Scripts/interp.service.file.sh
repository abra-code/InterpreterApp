# interp.service.file - "Translate with Interpreter" service on a document. macOS hands the
# selected file(s) in OMC_OBJ_PATH (newline-separated). We translate one document at a time, so we
# take the first path and open the document-translation window for it, reusing the same handoff as
# File > Open and app drop. A non-file selection (e.g. only a folder) is ignored.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"

first="$(/usr/bin/printf '%s' "$OMC_OBJ_PATH" | /usr/bin/sed -n '1p')"
[ -n "$first" ] && [ -f "$first" ] || exit 0

route_document "$first"

exit 0
