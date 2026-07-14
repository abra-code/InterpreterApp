# app.will.terminate - the app is quitting. Reap every bundled map broker and UI poller, then
# wipe the Sessions tree (which also makes any surviving broker exit on its next poll).

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"

# Terminate our bundled map brokers, verifying argv[0] so a recycled pid is never killed.
for ap in $(/usr/bin/pgrep -f "$AGENT_BIN" 2>/dev/null); do
    args=$(/bin/ps -p "$ap" -o args= 2>/dev/null)
    case "$args" in
        "$AGENT_BIN"|"$AGENT_BIN "*) /bin/kill -TERM "$ap" 2>/dev/null ;;
        *) : ;;
    esac
done

# Terminate the UI pollers, verifying argv (a /bin/sh running our poll script) so a recycled
# pid or an unrelated process that merely mentions the path is never killed.
for pp in $(/usr/bin/pgrep -f "$SCRIPTS_DIR/interp.poll.sh" 2>/dev/null); do
    pargs=$(/bin/ps -p "$pp" -o args= 2>/dev/null)
    case "$pargs" in
        */bin/sh\ *"$SCRIPTS_DIR/interp.poll.sh"*) /bin/kill -TERM "$pp" 2>/dev/null ;;
        *) : ;;
    esac
done

# Wipe the regenerated per-window spool tree.
[ -d "$SESSIONS_DIR" ] && /bin/rm -rf "$SESSIONS_DIR"

exit 0
