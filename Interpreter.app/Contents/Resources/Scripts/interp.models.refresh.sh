# interp.models.refresh - re-run the background catalog load for the chooser (Refresh button).
# In a chooser the app opened by itself the same button reads Show Models, and this is the first
# load (interp.models.init left the offer marker): the button becomes Refresh from here on.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"

marker="$DOWNLOADS_DIR/.chooser.$window_uuid"
if [ -f "$marker/offer" ]; then
    /bin/rm -f "$marker/offer"
    "$dialog" "$window_uuid" 930 omc_set_property "title" "Refresh"
    "$dialog" "$window_uuid" 910 "Finding the best models for your Mac…"
else
    "$dialog" "$window_uuid" 910 "Refreshing…"
fi
/bin/sh "$MODELS_LOAD_SCRIPT" "$window_uuid" \
    < /dev/null > "$CACHE_DIR/load.log" 2>&1 &

exit 0
