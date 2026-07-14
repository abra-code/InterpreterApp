# interp.model.changed - the Model picker changed. Resolve the 1-based index against the
# poller-maintained `modelpaths` index file. The final option is the synthetic
# "Download models…" sentinel (index = number-of-models + 1): selecting it opens the model
# chooser and restores the picker to the current model. Any real model index is written to
# `model.dir`; the poller notices the change and (re)spawns the broker. The write is idempotent
# so the poller's own selection refreshes (which re-fire this handler) are no-ops.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"

idx="$OMC_ACTIONUI_VIEW_25_VALUE"
case "$idx" in ''|*[!0-9]*) exit 0 ;; esac

spool=$(spool_dir_for "$window_uuid")
[ -d "$spool" ] || exit 0
[ -f "$spool/modelpaths" ] || exit 0

# Ignore the transitional actionID fires the poller's own option/value updates provoke (see the
# quiet window it writes). A genuine user selection lands outside this window.
quiet=$(/bin/cat "$spool/picker_quiet" 2>/dev/null)
case "$quiet" in ''|*[!0-9]*) quiet=0 ;; esac
now=$(/bin/date +%s)
[ "$now" -le "$quiet" ] && exit 0

n=$(/usr/bin/wc -l < "$spool/modelpaths" | /usr/bin/tr -d ' ')
case "$n" in ''|*[!0-9]*) n=0 ;; esac

# Sentinel (last option): open the chooser, then snap the picker back to the current model so it
# does not appear "stuck" on "Download models…".
if [ "$idx" -gt "$n" ]; then
    cur=$(/bin/cat "$spool/model.dir" 2>/dev/null)
    if [ -n "$cur" ]; then
        ci=$(/usr/bin/grep -Fxn "$cur" "$spool/modelpaths" 2>/dev/null | /usr/bin/head -1 | /usr/bin/cut -d: -f1)
        case "$ci" in ''|*[!0-9]*) ci=1 ;; esac
        "$dialog" "$window_uuid" "$MODEL_PICKER" "$ci"
    fi
    "$next_command" "$OMC_CURRENT_COMMAND_GUID" "interp.models"
    exit 0
fi

sel=$(/usr/bin/sed -n "${idx}p" "$spool/modelpaths")
[ -n "$sel" ] && [ -d "$sel" ] || exit 0

cur=$(/bin/cat "$spool/model.dir" 2>/dev/null)
[ "$sel" = "$cur" ] && exit 0     # already selected (poller refresh re-fire): nothing to do

/usr/bin/printf '%s' "$sel" > "$spool/model.dir.tmp" && /bin/mv "$spool/model.dir.tmp" "$spool/model.dir"

exit 0
