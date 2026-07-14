# interp.models.cancel - the model chooser window closed. Remove this window's marker dir, which
# stops its download-state poller. In-progress downloads are intentionally left running (the
# worker is UI-decoupled and continues in the background); reopening the chooser reconnects to
# them via the poller.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"

[ -n "$window_uuid" ] && /bin/rm -rf "$DOWNLOADS_DIR/.chooser.$window_uuid"

exit 0
