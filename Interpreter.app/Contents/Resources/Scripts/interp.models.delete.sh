# interp.models.delete - an installed card's trash icon. DOES NOT delete: presents the
# destructive confirmation alert and stashes which model is pending in the chooser's marker
# dir; interp.models.delete.confirm (the alert's Delete button) does the actual removal.
# Alert button actions carry no per-row context, hence the pending file.

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
label=$(/usr/bin/printf '%s' "$line" | /usr/bin/cut -f5)
[ -n "$repo" ] || exit 0
model_installed_at "$MODELS_DIR/$repo" || exit 0

marker="$DOWNLOADS_DIR/.chooser.$window_uuid"
/bin/mkdir -p "$marker"
/usr/bin/printf '%s' "$repo" > "$marker/pending.delete"

sz=$(/usr/bin/du -sk "$MODELS_DIR/$repo" 2>/dev/null | /usr/bin/awk '{ printf "%.1f GB", $1 * 1024 / 1000000000 }')
"$dialog" "$window_uuid" omc_window omc_present_alert "Delete $label?" \
"This removes the model (${sz:-installed}) from your Mac. You can download it again later. If a translation window is using it, it will switch to another installed model." \
"Cancel:cancel:" "Delete:destructive:interp.models.delete.confirm"

exit 0
