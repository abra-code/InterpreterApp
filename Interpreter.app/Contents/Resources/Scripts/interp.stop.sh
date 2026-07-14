# interp.stop - request cancellation of the current translation. The map broker checks the
# stop flag between and during chunks; the poller reflects the resulting "cancelled" state.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"

spool=$(spool_dir_for "$window_uuid")
[ -d "$spool" ] || exit 0

/usr/bin/touch "$spool/stop"
set_status "Stopping…"

exit 0
