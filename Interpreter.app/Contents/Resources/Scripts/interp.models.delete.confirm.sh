# interp.models.delete.confirm - the Delete button of the confirmation alert presented by
# interp.models.delete. Reads the pending model name stashed in the chooser's marker dir,
# removes the installed model plus any download leftovers, and rebuilds the cards so the row
# reverts to a Download button. The name is validated as a bare directory name before rm -rf
# (defense against a corrupted pending file - never delete outside Models/Downloads).

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.models.sh"

marker="$DOWNLOADS_DIR/.chooser.$window_uuid"
repo=$(/bin/cat "$marker/pending.delete" 2>/dev/null)
/bin/rm -f "$marker/pending.delete"

[ -n "$repo" ] || exit 0
case "$repo" in */*|.|..|.*) exit 0 ;; esac

/bin/rm -rf "$MODELS_DIR/$repo" "$DOWNLOADS_DIR/$repo" "$DOWNLOADS_DIR/$repo.log"

# Rebuild the cards (same spawn as Refresh): the render signature includes install state, so
# the deleted row's card comes back with its Download button; the row poller's sig files are
# cleared by the rebuild. Translation-window pollers notice the missing dir on their next tick
# and switch models on their own.
"$dialog" "$window_uuid" 910 "Deleted $repo."
/bin/mkdir -p "$CACHE_DIR"
/bin/sh "$MODELS_LOAD_SCRIPT" "$window_uuid" \
    < /dev/null > "$CACHE_DIR/load.log" 2>&1 &

exit 0
