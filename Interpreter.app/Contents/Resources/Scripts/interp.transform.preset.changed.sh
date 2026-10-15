# interp.transform.preset.changed - the Transform picker changed. Resolve the 1-based index through
# the spool's presetfiles index, make it the window's transform (on the model last picked for it,
# see select_transform; the poller follows: new model list for its families, broker restarted with
# its settings) and remember it for new windows.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.transform.sh"

idx="$OMC_ACTIONUI_VIEW_22_VALUE"
case "$idx" in ''|*[!0-9]*) exit 0 ;; esac

spool=$(spool_dir_for "$window_uuid")
[ -d "$spool" ] || exit 0
[ -f "$spool/presetfiles" ] || exit 0

# Ignore the echo of populate_preset_picker's own programmatic selection.
quiet=$(/bin/cat "$spool/preset_quiet" 2>/dev/null)
case "$quiet" in ''|*[!0-9]*) quiet=0 ;; esac
now=$(/bin/date +%s)
[ "$now" -le "$quiet" ] && exit 0

sel=$(/usr/bin/sed -n "${idx}p" "$spool/presetfiles")
[ -n "$sel" ] && [ -f "$sel" ] || exit 0
# The same transform again (its variants share an id) is no switch.
cur="$(/bin/cat "$spool/preset.file" 2>/dev/null)"
[ "$sel" = "$cur" ] && exit 0
sel_id="$(preset_get "$sel" id)"
[ -n "$sel_id" ] && [ -f "$cur" ] && [ "$sel_id" = "$(preset_get "$cur" id)" ] && exit 0

select_transform "$spool" "$sel"
"$defaults_tool" write "$BUNDLE_ID" TransformPreset "$sel_id"

exit 0
