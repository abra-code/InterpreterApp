# interp.service.transform.file - "Rewrite with Interpreter" service on a document. Takes the
# first selected file (OMC_OBJ_PATH is newline-separated) and opens the Text Transform document
# window on it, through the same handoff as File > Open for Text Transform.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"

first="$(/usr/bin/printf '%s' "$OMC_OBJ_PATH" | /usr/bin/sed -n '1p')"
[ -n "$first" ] || exit 0
# An RTFD document (one of the service's file types) is a package, that is a folder, so it is let
# through by its extension; any other folder is ignored.
case "$first" in
    *.rtfd|*.rtfd/|*.RTFD|*.RTFD/) [ -d "$first" ] || exit 0 ;;
    *) [ -f "$first" ] || exit 0 ;;
esac

route_transform_document "$first"

exit 0
