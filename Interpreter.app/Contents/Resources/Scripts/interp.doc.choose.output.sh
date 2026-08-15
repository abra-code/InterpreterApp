# interp.doc.choose.output - redirect where the translation is saved. Runs after the SAVE_AS_DIALOG
# has set OMC_DLG_SAVE_AS_PATH; records the new path and reflects it into the Output field, and
# remembers it as this window's output for the selected language. The next Translate settles its
# destination from that memo, so the choice takes effect from then on.
#
# The choice is remembered against the language currently selected, the same way a derived name is,
# so switching To away and back returns to the path the user picked instead of re-deriving a
# default one over the top of it. That language is read from the To PICKER, not from the spool's
# to.code: a pick made inside populate's quiet window leaves to.code behind (the change handler
# deliberately does nothing there), and memoizing under a stale code would file this choice under
# the wrong language - where the next Translate, which settles the destination from the memo for
# the language it dispatches, would never find it.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"

out="$OMC_DLG_SAVE_AS_PATH"
[ -n "$out" ] || exit 0

spool=$(spool_dir_for "$window_uuid")
[ -d "$spool" ] || exit 0

/usr/bin/printf '%s' "$out" > "$spool/output.path"
"$dialog" "$window_uuid" "$OUTPUT_PATH_TEXT" "$out"
# The picker first, the spool's cache second: the two fail in different ways - the picker can be
# transitional or out of range while its options are being replaced, the cache can be stale inside
# the quiet window - and either answer is better than none. With no language at all the memo is not
# written, and the next Translate would derive a name over this choice.
to_code=$(resolve_lang_code "$spool" "$OMC_ACTIONUI_VIEW_21_VALUE")
[ -n "$to_code" ] || to_code=$(/bin/cat "$spool/to.code" 2>/dev/null)
doc_remember_output "$spool" "$to_code" "$out"

exit 0
