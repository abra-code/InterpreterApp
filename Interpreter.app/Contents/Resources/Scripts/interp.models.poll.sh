# interp.models.poll.sh - chooser-scoped download-state poller, one per chooser window. Spawned
# by interp.models.init. Reflects each model's background download state (written by the
# UI-decoupled worker) into that tier's slot, so a download's progress shows correctly whether it
# was started in THIS chooser window or an earlier one that was closed and reopened. Runs until
# the per-window marker dir disappears (window close / app quit). Not an OMC command.
#   args: <chooser_window_uuid>
#
# Division of labour: interp.models.load fills the STATIC catalog rows (name, size, description,
# and the installed badge). This poller only OVERLAYS the dynamic state of an ACTIVE or FAILED
# download onto a slot; when there is no work dir for a tier it leaves load's static content alone.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.models.sh"

window_uuid="$1"
marker="$DOWNLOADS_DIR/.chooser.$window_uuid"
tab=$(/usr/bin/printf '\t')

# Reflect one tier's download state. Dedupes via a per-tier sig file in the marker dir so we only
# push to the UI when the display actually changes.
reflect_tier() {   # $1=tier $2=repo $3=catalog_size $4=badge_id $5=size_id $6=btn_id
    local _tier="$1" _repo="$2" _csize="$3" _badge="$4" _sz="$5" _btn="$6"
    local _work="$DOWNLOADS_DIR/$_repo" _sigf="$marker/$_tier.sig"
    local _state _total _text _btnstate _got _pct _sig

    if [ -f "$_work/state" ]; then
        _state=$(/bin/cat "$_work/state" 2>/dev/null)
        _total=$(/bin/cat "$_work/total" 2>/dev/null); case "$_total" in ''|*[!0-9]*) _total="$_csize" ;; esac
        case "$_state" in
            preparing)  _text="Preparing…"; _btnstate=off ;;
            installing) _text="Finishing…"; _btnstate=off ;;
            error)      _text=$(/bin/cat "$_work/message" 2>/dev/null); _btnstate=on ;;
            done)       _text="Installed - $(bytes_to_gb "$_total")"; _btnstate=off ;;
            downloading)
                _got=$(/usr/bin/du -sk "$_work/staging" 2>/dev/null | /usr/bin/awk '{ print $1 * 1024; exit }')
                case "$_got" in ''|*[!0-9]*) _got=0 ;; esac
                if [ "$_total" -ge 1 ] 2>/dev/null; then
                    _pct=$(( _got * 100 / _total )); [ "$_pct" -gt 100 ] && _pct=100
                    _text="Downloading $(bytes_to_gb "$_got") of $(bytes_to_gb "$_total") ($_pct%)…"
                else
                    _text="Downloading $(bytes_to_gb "$_got")…"
                fi
                _btnstate=off ;;
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
    elif [ -f "$MODELS_DIR/$_repo/config.json" ]; then
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
        while IFS="$tab" read -r _t _repo _label _size _rec _heavy _desc; do
            case "$_t" in
                best)     reflect_tier best     "$_repo" "$_size" 1002 1004 1005 ;;
                balanced) reflect_tier balanced "$_repo" "$_size" 1012 1014 1015 ;;
                faster)   reflect_tier faster   "$_repo" "$_size" 1022 1024 1025 ;;
            esac
        done < "$CACHE_DIR/curated.tsv"
    fi
    /bin/sleep 1
done
