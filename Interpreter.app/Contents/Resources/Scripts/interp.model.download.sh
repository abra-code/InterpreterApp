# interp.model.download - a tier's Download button was clicked in the chooser. Resolve which
# tier from the trigger view id, look up its repo in the curated catalog, do a disk preflight,
# then spawn the background download worker (which streams the files and updates the slot).

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.models.sh"

case "$OMC_ACTIONUI_TRIGGER_VIEW_ID" in
    1005) tier=best;     size_id=1004; btn_id=1005; badge_id=1002 ;;
    1015) tier=balanced; size_id=1014; btn_id=1015; badge_id=1012 ;;
    1025) tier=faster;   size_id=1024; btn_id=1025; badge_id=1022 ;;
    *) exit 0 ;;
esac

[ -f "$CACHE_DIR/curated.tsv" ] || exit 0
tab=$(/usr/bin/printf '\t')
repo=""; size=""
while IFS="$tab" read -r t r l sz rec heavy desc; do
    [ "$t" = "$tier" ] || continue
    repo="$r"; size="$sz"; break
done < "$CACHE_DIR/curated.tsv"
[ -n "$repo" ] || exit 0

# Already installed (a stale window, or a race): nothing to do.
if [ -f "$MODELS_DIR/$repo/config.json" ]; then
    "$dialog" "$window_uuid" "$badge_id" "Installed"
    "$dialog" "$window_uuid" "$btn_id" omc_disable
    exit 0
fi

work="$DOWNLOADS_DIR/$repo"
/bin/mkdir -p "$work"

# Serialize the check-claim-spawn against a rapid second click / a reopened window's re-enabled
# button: an atomic mkdir lock makes the "is a download already active?" test and the state claim
# indivisible, so only one worker is ever spawned per staging dir. Held for this handler's whole
# run (released on any exit); once state=preparing is written the state guard covers later clicks.
/bin/mkdir "$work/dispatch.lock" 2>/dev/null || { "$dialog" "$window_uuid" "$btn_id" omc_disable; exit 0; }
trap '/bin/rmdir "$work/dispatch.lock" 2>/dev/null' EXIT

# Already downloading (or installing): the poller is showing its progress; do not start another.
st=$(/bin/cat "$work/state" 2>/dev/null)
case "$st" in
    preparing|downloading|installing) "$dialog" "$window_uuid" "$btn_id" omc_disable; exit 0 ;;
esac

# Disk preflight against the Models volume (need the download plus ~10% slack for the atomic
# move into place). `size` is the catalog's reported total; the worker re-checks precisely.
case "$size" in ''|*[!0-9]*) size=0 ;; esac
free=$(disk_free_bytes "$MODELS_DIR")
case "$free" in ''|*[!0-9]*) free=0 ;; esac
if [ "$size" -gt 0 ] && [ "$free" -gt 0 ] && [ "$free" -lt $(( size + size / 10 )) ]; then
    "$dialog" "$window_uuid" "$size_id" "Not enough free disk space (needs about $(bytes_to_gb "$size"))."
    exit 0
fi

/usr/bin/printf '%s' preparing > "$work/state"
"$dialog" "$window_uuid" "$btn_id" omc_disable
"$dialog" "$window_uuid" "$size_id" "Preparing download…"

/bin/sh "$SCRIPTS_DIR/interp.download.worker.sh" "$repo" \
    < /dev/null >> "$DOWNLOADS_DIR/$repo.log" 2>&1 &

exit 0
