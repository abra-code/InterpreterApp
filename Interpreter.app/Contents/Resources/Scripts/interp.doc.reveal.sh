# interp.doc.reveal - show the translated output file in the Finder. Only meaningful once the
# translation has been written; the button is enabled by the poller on completion.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"

spool=$(spool_dir_for "$window_uuid")
out="$(/bin/cat "$spool/output.path" 2>/dev/null)"
[ -n "$out" ] && [ -e "$out" ] && /usr/bin/open -R "$out"

exit 0
