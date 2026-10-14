# interp.tdoc.choose.output - redirect where the document window's result is saved. Runs after
# the SAVE_AS_DIALOG has set OMC_DLG_SAVE_AS_PATH. The transform twin of interp.doc.choose.output:
# the choice is remembered against the CURRENT preset's output suffix (the translator remembers it
# against the target language), so switching presets away and back returns to the chosen path.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.transform.sh"

out="$OMC_DLG_SAVE_AS_PATH"
[ -n "$out" ] || exit 0

spool=$(spool_dir_for "$window_uuid")
[ -d "$spool" ] || exit 0

/usr/bin/printf '%s' "$out" > "$spool/output.path"
"$dialog" "$window_uuid" "$OUTPUT_PATH_TEXT" "$out"
preset="$(/bin/cat "$spool/preset.file" 2>/dev/null)"
[ -n "$preset" ] && doc_remember_output "$spool" "$(transform_output_suffix "$preset")" "$out"

exit 0
