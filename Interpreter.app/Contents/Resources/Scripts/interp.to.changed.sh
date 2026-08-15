# interp.to.changed - persist the To-language selection. The picker delivers a 1-based index
# into the CURRENT (possibly family-filtered) option list; persist the language CODE it
# resolves to - an index would point at a different language whenever the family list changes.
# Guard the value: programmatic option/value updates can fire this with a transitional/bogus value.
#
# In the document window the To language also names the output FILE ("report-es.txt"), so a change
# here re-derives the destination and takes the right-hand preview off the previous language's
# translation. Shared with the text window, where neither applies.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"

idx="$OMC_ACTIONUI_VIEW_21_VALUE"
case "$idx" in ''|*[!0-9]*) exit 0 ;; esac
spool=$(spool_dir_for "$window_uuid")

# Inside populate's quiet window this fire is a programmatic restore (possibly a family-filter
# fallback), not a user choice - do not let it overwrite the saved preference.
quiet=$(/bin/cat "$spool/lang_quiet" 2>/dev/null)
case "$quiet" in ''|*[!0-9]*) quiet=0 ;; esac
[ "$(/bin/date +%s)" -le "$quiet" ] && exit 0

code=$(resolve_lang_code "$spool" "$idx")
[ -n "$code" ] || exit 0
"$defaults_tool" write "$BUNDLE_ID" ToLang "$code"

if [ -d "$spool" ]; then
    /usr/bin/printf '%s' "$code" > "$spool/to.code"
    if [ "$(/bin/cat "$spool/mode" 2>/dev/null)" = doc ]; then
        refresh_doc_output "$spool" "$code"
    fi
fi

exit 0
