# interp.models.refresh - re-run the background catalog load for the chooser (Refresh button).

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"

"$dialog" "$window_uuid" 910 "Refreshing…"
/bin/sh "$MODELS_LOAD_SCRIPT" "$window_uuid" \
    < /dev/null > "$CACHE_DIR/load.log" 2>&1 &

exit 0
