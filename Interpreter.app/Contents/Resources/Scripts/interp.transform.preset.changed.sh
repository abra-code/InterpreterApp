# interp.transform.preset.changed - the Transform picker changed. Resolve the 1-based index through
# the spool's presetfiles index, make it the window's preset (the poller follows: new model list
# for the preset's family, broker restarted with its settings) and remember it for new windows.

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
[ "$sel" = "$(/bin/cat "$spool/preset.file" 2>/dev/null)" ] && exit 0

apply_preset "$spool" "$sel"
"$defaults_tool" write "$BUNDLE_ID" TransformPreset "$(preset_get "$sel" id)"

exit 0
