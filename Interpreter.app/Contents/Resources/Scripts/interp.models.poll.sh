# interp.models.poll.sh - chooser-scoped download-state poller, one per chooser window. Spawned
# by interp.models.init. Reflects each model's background download state (written by the
# UI-decoupled worker) into that model's CARD, so a download's progress shows correctly whether
# it was started in THIS chooser window or an earlier one that was closed and reopened. Runs
# until the per-window marker dir disappears (window close / app quit). Not an OMC command.
#   args: <chooser_window_uuid>
#
# Division of labour: interp.models.load builds the cards with their STATIC content (name, size,
# description, and the installed badge). This poller only OVERLAYS the dynamic state of an
# ACTIVE or FAILED download onto a card; when there is no work dir for a row it leaves load's
# static content alone. Card view ids derive from the curated row number (interp_card_base_id);
# load clears this poller's per-row sig files whenever it rebuilds cards, so fresh cards always
# get a re-push within one tick.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.models.sh"

window_uuid="$1"
marker="$DOWNLOADS_DIR/.chooser.$window_uuid"
tab=$(/usr/bin/printf '\t')

# Reflect one curated row's download state. Dedupes via a per-row sig file in the marker dir so
# we only push to the UI when the display actually changes.
reflect_row() {   # $1=row $2=repo $3=catalog_size
    local _row="$1" _repo="$2" _csize="$3"
    local _base=$(interp_card_base_id "$_row")
    local _badge=$((_base + 2)) _sz=$((_base + 4)) _btn=$((_base + 5))
    local _work="$DOWNLOADS_DIR/$_repo" _sigf="$marker/row.$_row.sig"
    local _state _total _text _btnstate _got _pct _sig

    if [ -f "$_work/state" ]; then
        _state=$(/bin/cat "$_work/state" 2>/dev/null)
        _total=$(/bin/cat "$_work/total" 2>/dev/null); case "$_total" in ''|*[!0-9]*) _total="$_csize" ;; esac
        # An in-flight state with a DEAD worker (SIGKILL, crash - the worker's own TERM trap
        # normally converts an app-quit into state=error itself) shows as interrupted and
        # re-enables the button; the download handler's matching liveness check then respawns
        # the worker, whose curl -C - resumes the partial. For "preparing" the pid file must
        # EXIST to rule the worker dead: the button handler writes it under its dispatch lock,
        # but a legacy stuck dir might have neither pid nor progress worth special-casing.
        case "$_state" in
            preparing)
                if [ -f "$_work/worker.pid" ] && ! download_worker_alive "$_work"; then
                    _text="Download interrupted - click Download to resume."; _btnstate=on
                else
                    _text="Preparing…"; _btnstate=off
                fi ;;
            installing)
                if download_worker_alive "$_work"; then _text="Finishing…"; _btnstate=off
                else _text="Download interrupted - click Download to resume."; _btnstate=on; fi ;;
            error)      _text=$(/bin/cat "$_work/message" 2>/dev/null); _btnstate=on ;;
            done)       _text="Installed - $(bytes_to_gb "$_total")"; _btnstate=off ;;
            downloading)
                if download_worker_alive "$_work"; then
                    _got=$(/usr/bin/du -sk "$_work/staging" 2>/dev/null | /usr/bin/awk '{ print $1 * 1024; exit }')
                    case "$_got" in ''|*[!0-9]*) _got=0 ;; esac
                    if [ "$_total" -ge 1 ] 2>/dev/null; then
                        _pct=$(( _got * 100 / _total )); [ "$_pct" -gt 100 ] && _pct=100
                        _text="Downloading $(bytes_to_gb "$_got") of $(bytes_to_gb "$_total") ($_pct%)…"
                    else
                        _text="Downloading $(bytes_to_gb "$_got")…"
                    fi
                    _btnstate=off
                else
                    _text="Download interrupted - click Download to resume."; _btnstate=on
                fi ;;
            *) return 0 ;;
        esac
        _sig="$_state|$_text|$_btnstate"
        [ "$_sig" = "$(/bin/cat "$_sigf" 2>/dev/null)" ] && return 0
        /usr/bin/printf '%s' "$_sig" > "$_sigf"
        "$dialog" "$window_uuid" "$_sz" "$_text"
        if [ "$_state" = done ]; then "$dialog" "$window_uuid" "$_badge" "Installed"; fi
        if [ "$_btnstate" = off ]; then "$dialog" "$window_uuid" "$_btn" omc_disable
        else "$dialog" "$window_uuid" "$_btn" omc_enable; fi
        # A finished download's work dir is no longer needed; the installed model speaks for itself.
        [ "$_state" = done ] && /bin/rm -rf "$_work"
    elif model_installed_at "$MODELS_DIR/$_repo"; then
        # Installed with no active download: make sure the badge/button reflect that (load also
        # does this, but a just-completed download that cleaned its work dir passes through here).
        _sig="installed"
        [ "$_sig" = "$(/bin/cat "$_sigf" 2>/dev/null)" ] && return 0
        /usr/bin/printf '%s' "$_sig" > "$_sigf"
        "$dialog" "$window_uuid" "$_badge" "Installed"
        "$dialog" "$window_uuid" "$_btn" omc_disable
    else
        /bin/rm -f "$_sigf"   # nothing active: let load's static content stand
    fi
}

while [ -d "$marker" ]; do
    if [ -f "$CACHE_DIR/curated.tsv" ]; then
        row=0
        while IFS="$tab" read -r _sec _fam _auth _repo _label _size _heavy _desc; do
            [ -n "$_sec" ] || continue
            row=$((row + 1))
            reflect_row "$row" "$_repo" "$_size"
        done < "$CACHE_DIR/curated.tsv"
    fi
    /bin/sleep 1
done
