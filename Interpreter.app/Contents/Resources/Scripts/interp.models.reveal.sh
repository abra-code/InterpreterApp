# interp.models.reveal - an installed card's folder icon: show the model directory in Finder.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.models.sh"

case "$OMC_ACTIONUI_TRIGGER_VIEW_ID" in ''|*[!0-9]*) exit 0 ;; esac
[ "$OMC_ACTIONUI_TRIGGER_VIEW_ID" -gt 2000 ] 2>/dev/null || exit 0
row=$(interp_card_row_of_id "$OMC_ACTIONUI_TRIGGER_VIEW_ID")

[ -f "$CACHE_DIR/curated.tsv" ] || exit 0
tab=$(/usr/bin/printf '\t')
line=$(curated_row "$CACHE_DIR/curated.tsv" "$row")
[ -n "$line" ] || exit 0
repo=$(/usr/bin/printf '%s' "$line" | /usr/bin/cut -f4)
[ -n "$repo" ] || exit 0

dest="$MODELS_DIR/$repo"
[ -d "$dest" ] && /usr/bin/open -R "$dest"

exit 0
