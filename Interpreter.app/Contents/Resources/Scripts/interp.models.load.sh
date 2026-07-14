# interp.models.load.sh - backgrounded catalog load for the model chooser. Queries the live
# mlx-community catalog, curates it against this Mac's RAM, and fills the three tier slots
# (best / balanced / faster). Launched by interp.models.init and interp.models.refresh.
#   args: <chooser_window_uuid>
# Not an OMC command - run directly via /bin/sh.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.models.sh"

window_uuid="$1"

/bin/mkdir -p "$CACHE_DIR"

# Two overlapping loads (reopen during a load, or a fast double Refresh) share these cache files,
# so build per-process temp files and move them into place atomically - the last writer wins
# cleanly instead of two writers interleaving lines.
cat_tmp="$CACHE_DIR/catalog.$$.tsv"
cur_tmp="$CACHE_DIR/curated.$$.tsv"
/bin/rm -f "$cat_tmp" "$cur_tmp"

if ! interp_fetch_catalog "$cat_tmp"; then
    /bin/rm -f "$cat_tmp"
    "$dialog" "$window_uuid" 910 "Could not reach the model catalog. Check your connection and click Refresh."
    exit 0
fi
/bin/mv "$cat_tmp" "$CACHE_DIR/catalog.tsv"

if ! interp_curate_models "$CACHE_DIR/catalog.tsv" > "$cur_tmp" || [ ! -s "$cur_tmp" ]; then
    /bin/rm -f "$cur_tmp"
    "$dialog" "$window_uuid" 910 "No suitable model fits this Mac's memory. Click Refresh to try again."
    exit 0
fi
/bin/mv "$cur_tmp" "$CACHE_DIR/curated.tsv"

tab=$(/usr/bin/printf '\t')
while IFS="$tab" read -r tier repo label size rec heavy desc; do
    [ -n "$tier" ] || continue
    case "$tier" in
        best)     box=1000; lbl_id=1001; badge_id=1002; desc_id=1003; size_id=1004; btn_id=1005; head="Best quality" ;;
        balanced) box=1010; lbl_id=1011; badge_id=1012; desc_id=1013; size_id=1014; btn_id=1015; head="Balanced" ;;
        faster)   box=1020; lbl_id=1021; badge_id=1022; desc_id=1023; size_id=1024; btn_id=1025; head="Faster" ;;
        *) continue ;;
    esac

    installed=0
    [ -f "$MODELS_DIR/$repo/config.json" ] && installed=1

    if [ "$installed" = 1 ]; then
        badge="Installed"
    elif [ "$rec" = 1 ]; then
        badge="Recommended"
    elif [ "$heavy" = 1 ]; then
        badge="Heavy"
    else
        badge=""
    fi

    "$dialog" "$window_uuid" "$lbl_id"   "$head"
    "$dialog" "$window_uuid" "$badge_id" "$badge"
    "$dialog" "$window_uuid" "$desc_id"  "$desc"
    # For a tier with an active download, leave the size text AND the button entirely to the
    # download poller - writing our static "TranslateGemma X - Y GB" here (this catalog fetch can
    # take several seconds) would stomp the poller's live "Downloading …%" progress on reopen /
    # Refresh. Otherwise show the static size line and enable/disable by installed state.
    wstate=$(/bin/cat "$DOWNLOADS_DIR/$repo/state" 2>/dev/null)
    case "$wstate" in
        preparing|downloading|installing)
            "$dialog" "$window_uuid" "$btn_id" omc_disable ;;
        *)
            "$dialog" "$window_uuid" "$size_id" "TranslateGemma $label - $(bytes_to_gb "$size")"
            if [ "$installed" = 1 ]; then
                "$dialog" "$window_uuid" "$btn_id" omc_disable
            else
                "$dialog" "$window_uuid" "$btn_id" omc_enable
            fi ;;
    esac
    "$dialog" "$window_uuid" "$box" omc_show
done < "$CACHE_DIR/curated.tsv"

"$dialog" "$window_uuid" 910 ""

exit 0
