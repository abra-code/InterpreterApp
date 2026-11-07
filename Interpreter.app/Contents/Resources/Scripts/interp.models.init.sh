# interp.models.init - fired when the model chooser window loads. Hides the (still empty)
# section groups and kicks off a background load that queries the model catalog, curates it
# for this Mac's RAM, and inserts the model cards. The network work is backgrounded so the
# window paints immediately.
#
# A chooser the app opened by itself (interp.models.offer.init and interp.tmodels.offer.init set
# INTERP_CHOOSER_OFFER=1 and source this) does not query the catalog: the user has not asked for
# anything yet, and the query contacts Hugging Face. It says so and turns Refresh into Show
# Models; interp.models.refresh starts the load when the user clicks it.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"

/bin/mkdir -p "$CACHE_DIR" "$DOWNLOADS_DIR" "$MODELS_DIR"

# Per-window marker dir: it bounds the download-state poller's lifetime (removed on window close)
# and holds its per-row UI-dedup sig files plus the inserted-card id list.
marker="$DOWNLOADS_DIR/.chooser.$window_uuid"
/bin/mkdir -p "$marker"

for sec_box in 1100 1200 1300; do
    "$dialog" "$window_uuid" "$sec_box" omc_hide
done

if [ "${INTERP_CHOOSER_OFFER:-}" = 1 ]; then
    # Remembered for interp.models.refresh, which turns the button back into Refresh.
    : > "$marker/offer"
    "$dialog" "$window_uuid" 930 omc_set_property "title" "Show Models"
    "$dialog" "$window_uuid" 910 "No model is installed yet. Show Models asks Hugging Face which ones fit your Mac."
    # The cards an earlier check found, read from the cache only: a download the user started,
    # running or failed, shows on its card (the download poller fills it in) without the network.
    if [ -s "$CACHE_DIR/curated.tsv" ]; then
        /bin/sh "$MODELS_LOAD_SCRIPT" "$window_uuid" cached \
            < /dev/null > "$CACHE_DIR/load.log" 2>&1 &
    fi
else
    "$dialog" "$window_uuid" 910 "Finding the best models for your Mac…"
    # Static catalog fill (network, one-shot).
    /bin/sh "$MODELS_LOAD_SCRIPT" "$window_uuid" \
        < /dev/null > "$CACHE_DIR/load.log" 2>&1 &
fi

# The download-state poller (reflects in-progress or failed downloads into the slots, so
# reopening the chooser reconnects to a running download). It reads local state only.
/bin/sh "$MODELS_POLL_SCRIPT" "$window_uuid" \
    < /dev/null > "$CACHE_DIR/poll.log" 2>&1 &

exit 0
