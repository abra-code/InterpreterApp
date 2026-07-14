# interp.doc.choose.output - redirect where the translation is saved. Runs after the SAVE_AS_DIALOG
# has set OMC_DLG_SAVE_AS_PATH; records the new path and reflects it into the Output field. The
# poller reads output.path when it writes the finished translation, so this takes effect on the
# next Translate.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"

out="$OMC_DLG_SAVE_AS_PATH"
[ -n "$out" ] || exit 0

spool=$(spool_dir_for "$window_uuid")
[ -d "$spool" ] || exit 0

/usr/bin/printf '%s' "$out" > "$spool/output.path"
"$dialog" "$window_uuid" "$OUTPUT_PATH_TEXT" "$out"

exit 0
