# interp.transform.model.changed - the Model picker of a Text Transform window changed. The
# transform twin of interp.model.changed: the last option is the "Download models..." sentinel,
# which opens the TRANSFORM model chooser, and a genuine pick is remembered under its own defaults
# key (TransformModelName) so it never disturbs the translator's saved model.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.transform.sh"

idx="$OMC_ACTIONUI_VIEW_25_VALUE"
case "$idx" in ''|*[!0-9]*) exit 0 ;; esac

spool=$(spool_dir_for "$window_uuid")
[ -d "$spool" ] || exit 0
[ -f "$spool/modelpaths" ] || exit 0

quiet=$(/bin/cat "$spool/picker_quiet" 2>/dev/null)
case "$quiet" in ''|*[!0-9]*) quiet=0 ;; esac
now=$(/bin/date +%s)
[ "$now" -le "$quiet" ] && exit 0

n=$(/usr/bin/wc -l < "$spool/modelpaths" | /usr/bin/tr -d ' ')
case "$n" in ''|*[!0-9]*) n=0 ;; esac

if [ "$idx" -gt "$n" ]; then
    cur=$(/bin/cat "$spool/model.dir" 2>/dev/null)
    if [ -n "$cur" ]; then
        ci=$(/usr/bin/grep -Fxn "$cur" "$spool/modelpaths" 2>/dev/null | /usr/bin/head -1 | /usr/bin/cut -d: -f1)
        case "$ci" in ''|*[!0-9]*) ci=1 ;; esac
        "$dialog" "$window_uuid" "$MODEL_PICKER" "$ci"
    fi
    "$next_command" "$OMC_CURRENT_COMMAND_GUID" "interp.tmodels"
    exit 0
fi

sel=$(/usr/bin/sed -n "${idx}p" "$spool/modelpaths")
[ -n "$sel" ] && [ -d "$sel" ] || exit 0

cur=$(/bin/cat "$spool/model.dir" 2>/dev/null)
[ "$sel" = "$cur" ] && exit 0

# Rewrite goes off until the poller has respawned the broker on the new model (see apply_preset).
disable_ctrl "$TRANSLATE_BTN"
/usr/bin/printf '%s' "$sel" > "$spool/model.dir.tmp" && /bin/mv "$spool/model.dir.tmp" "$spool/model.dir"
# A model of another family runs the transform's variant made for it (Humanize on the Humanizer
# or on Gemma 4), which also brings that variant's notice.
sync_preset_variant "$spool"
: > "$spool/ui.stale"      # after the switch is recorded: the poller re-renders the button
"$defaults_tool" write "$BUNDLE_ID" TransformModelName "$(/usr/bin/basename "$sel")"
# And for this transform, so switching to another transform and back returns to this model.
pref_key="$(transform_model_pref_key "$(/bin/cat "$spool/preset.file" 2>/dev/null)")"
[ -n "$pref_key" ] && "$defaults_tool" write "$BUNDLE_ID" "$pref_key" "$(/usr/bin/basename "$sel")"

exit 0
