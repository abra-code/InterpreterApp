# interp.window.cancel - the translator window is closing. Remove this window's spool
# directory, which makes both the map broker and the poller exit on their next poll.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"

spool=$(spool_dir_for "$window_uuid")
[ -n "$window_uuid" ] && [ -d "$spool" ] && /bin/rm -rf "$spool"

exit 0
