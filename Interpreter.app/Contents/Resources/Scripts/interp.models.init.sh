# interp.models.init - fired when the model chooser window loads. Hides the (still empty)
# section groups and kicks off a background load that queries the model catalog, curates it
# for this Mac's RAM, and inserts the model cards. The network work is backgrounded so the
# window paints immediately.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"

/bin/mkdir -p "$CACHE_DIR" "$DOWNLOADS_DIR" "$MODELS_DIR"

# Per-window marker dir: it bounds the download-state poller's lifetime (removed on window close)
# and holds its per-row UI-dedup sig files plus the inserted-card id list.
/bin/mkdir -p "$DOWNLOADS_DIR/.chooser.$window_uuid"

for sec_box in 1100 1200 1300; do
    "$dialog" "$window_uuid" "$sec_box" omc_hide
done
"$dialog" "$window_uuid" 910 "Finding the best models for your Mac…"

# Static catalog fill (network, one-shot) + the download-state poller (reflects in-progress or
# failed downloads into the slots, so reopening the chooser reconnects to a running download).
/bin/sh "$SCRIPTS_DIR/interp.models.load.sh" "$window_uuid" \
    < /dev/null > "$CACHE_DIR/load.log" 2>&1 &
/bin/sh "$SCRIPTS_DIR/interp.models.poll.sh" "$window_uuid" \
    < /dev/null > "$CACHE_DIR/poll.log" 2>&1 &

exit 0
