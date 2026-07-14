# interp.poll.sh - backgrounded UI poller, one per window. Spawned by interp.window.init.
# Reflects the map broker's spool files into the window: status.json -> status line + button
# state, result.txt -> the target editor. Runs until the spool directory disappears (window
# close / app quit), then exits. Not an OMC command - launched directly via /bin/sh.
#   args: <window_uuid> <spool_dir> <model_label>

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"

window_uuid="$1"       # override the (inherited) uuid with the explicit arg
spool="$2"
label="$3"

last_status_sig=""
last_result_sig=""

while [ -d "$spool" ]; do
    if [ -f "$spool/status.json" ]; then
        state=$("$plutil" -extract state raw -o - "$spool/status.json" 2>/dev/null)
        chunk=$("$plutil" -extract chunk raw -o - "$spool/status.json" 2>/dev/null)
        total=$("$plutil" -extract total raw -o - "$spool/status.json" 2>/dev/null)
        msg=$("$plutil" -extract message raw -o - "$spool/status.json" 2>/dev/null)
        sig="$state|$chunk|$total|$msg"
        if [ "$sig" != "$last_status_sig" ]; then
            last_status_sig="$sig"
            # Idle (ready/done/cancelled/error): Translate + Clear + Swap enabled, Stop off.
            # Busy (loading/mapping): those off, and Stop on only while mapping. Clear and Swap
            # are disabled while a job runs so they cannot race the per-chunk result writes the
            # poller reflects into the target pane.
            case "$state" in
                loading)
                    disable_ctrl "$TRANSLATE_BTN"; disable_ctrl "$CLEAR_BTN"
                    disable_ctrl "$SWAP_BTN"; disable_ctrl "$STOP_BTN"
                    set_status "Loading model…" ;;
                ready)
                    enable_ctrl "$TRANSLATE_BTN"; enable_ctrl "$CLEAR_BTN"
                    enable_ctrl "$SWAP_BTN"; disable_ctrl "$STOP_BTN"
                    set_status "Ready — $label" ;;
                mapping)
                    disable_ctrl "$TRANSLATE_BTN"; disable_ctrl "$CLEAR_BTN"
                    disable_ctrl "$SWAP_BTN"; enable_ctrl "$STOP_BTN"
                    set_status "Translating (${chunk:-0}/${total:-?})…" ;;
                done)
                    enable_ctrl "$TRANSLATE_BTN"; enable_ctrl "$CLEAR_BTN"
                    enable_ctrl "$SWAP_BTN"; disable_ctrl "$STOP_BTN"
                    set_status "Ready — $label" ;;
                cancelled)
                    enable_ctrl "$TRANSLATE_BTN"; enable_ctrl "$CLEAR_BTN"
                    enable_ctrl "$SWAP_BTN"; disable_ctrl "$STOP_BTN"
                    set_status "Cancelled." ;;
                error)
                    enable_ctrl "$TRANSLATE_BTN"; enable_ctrl "$CLEAR_BTN"
                    enable_ctrl "$SWAP_BTN"; disable_ctrl "$STOP_BTN"
                    set_status "Error: ${msg:-unknown}" ;;
            esac
        fi
    fi

    if [ -f "$spool/result.txt" ]; then
        rsig=$(/usr/bin/stat -f '%m %z' "$spool/result.txt" 2>/dev/null)
        if [ "$rsig" != "$last_result_sig" ]; then
            last_result_sig="$rsig"
            /bin/cat "$spool/result.txt" \
                | "$dialog" "$window_uuid" "$TGT_EDITOR" omc_set_value_from_stdin plain
        fi
    fi

    /bin/sleep 0.3
done
