# interp.download.worker.sh - background model downloader, one per download. UI-DECOUPLED: it
# writes only state files under the model's work dir; a chooser-scoped poller (interp.models.poll)
# reflects that state into whatever chooser window is open, so a download survives closing and
# reopening the chooser. Streams every file of a Hugging Face repo into a staging dir with
# resumable curl, then atomically moves the finished model into place (writing a Gemma NOTICE.txt
# beside it). Interrupted downloads leave staging intact so a later click resumes. Not an OMC
# command.  args: <hf_author> <repo_name>
#
# State files in the work dir ($DOWNLOADS_DIR/<name>):
#   state   : preparing | downloading | installing | done | error
#   total   : total download size in bytes (once known)
#   message : human error text (when state=error)

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.models.sh"

author="$1"
name="$2"
repo="$author/$name"
dest="$MODELS_DIR/$name"
work="$DOWNLOADS_DIR/$name"
staging="$work/staging"
tab=$(/usr/bin/printf '\t')

set_state() { /usr/bin/printf '%s' "$1" > "$work/state.tmp" && /bin/mv "$work/state.tmp" "$work/state"; }
set_err()   { /usr/bin/printf '%s' "$1" > "$work/message"; set_state error; exit 0; }

/bin/mkdir -p "$staging"
set_state preparing

# --- enumerate the repo's files (path <TAB> size, files only) ----------------
/usr/bin/curl -fsSL --connect-timeout 15 --max-time 60 --retry 3 --retry-delay 2 --retry-all-errors \
    "https://huggingface.co/api/models/$repo/tree/main?recursive=true" 2>/dev/null \
    | /usr/bin/plutil -p - 2>/dev/null \
    | /usr/bin/awk '
        function flush() { if (p != "" && type == "file") print p "\t" (s+0) }
        /^[[:space:]]*[0-9]+ => \{/ { flush(); p=""; s=""; counted=0; type="" }
        /"path" =>/ { v=$0; sub(/.*"path" => "/,"",v); sub(/".*/,"",v); p=v }
        /"type" =>/ { v=$0; sub(/.*"type" => "/,"",v); sub(/".*/,"",v); type=v }
        /"size" =>/ { if (!counted) { n=$3; gsub(/[^0-9]/,"",n); s=n; counted=1 } }
        END { flush() }' > "$work/files.tsv"

[ -s "$work/files.tsv" ] || set_err "Could not read the model file list. Click Download to retry."

total=$(/usr/bin/awk -F"$tab" '{ t += $2 } END { print t+0 }' "$work/files.tsv")
case "$total" in ''|0|*[!0-9]*) set_err "Could not read the model file list. Click Download to retry." ;; esac
/usr/bin/printf '%s' "$total" > "$work/total"

# Precise disk preflight now that the true total is known.
free=$(disk_free_bytes "$MODELS_DIR")
case "$free" in ''|*[!0-9]*) free=0 ;; esac
if [ "$free" -gt 0 ] && [ "$free" -lt $(( total + total / 10 )) ]; then
    set_err "Not enough free disk space (needs about $(bytes_to_gb "$total"))."
fi

# --- download all files (curl as a waited-on child, killable via the trap) ---
set_state downloading
curlpid=""
cleanup() { [ -n "$curlpid" ] && /bin/kill -TERM "$curlpid" 2>/dev/null; exit 0; }
trap cleanup TERM INT

rc=0
while IFS="$tab" read -r p s; do
    [ -n "$p" ] || continue
    # Reject a remote path that is absolute or escapes staging (defense against a bad catalog).
    case "$p" in /*) rc=1; break ;; esac
    case "/$p/" in */../*) rc=1; break ;; esac
    # Skip an already-complete file: resuming a full file with -C - would 416 under -f. If a
    # leftover partial is somehow LARGER than the now-expected size (upstream changed between a
    # failed attempt and this resume), it can never resume cleanly - drop it and re-fetch whole.
    if [ -f "$staging/$p" ]; then
        have=$(/usr/bin/stat -f %z "$staging/$p" 2>/dev/null)
        [ "$have" = "$s" ] && continue
        [ "$have" -gt "$s" ] 2>/dev/null && /bin/rm -f "$staging/$p"
    fi
    d=$(/usr/bin/dirname "$p")
    /bin/mkdir -p "$staging/$d"
    # --retry-all-errors: LFS weights redirect to the Xet CDN with a short-lived signed URL that
    # intermittently 401s; curl's default --retry ignores 4xx. Each retry re-hits resolve for a
    # FRESH signed URL. -C - resumes any partial bytes.
    /usr/bin/curl -fL -C - --retry 8 --retry-delay 2 --retry-all-errors --connect-timeout 30 -sS \
        -o "$staging/$p" "https://huggingface.co/$repo/resolve/main/$p" &
    curlpid=$!
    wait "$curlpid"; cst=$?
    curlpid=""
    [ "$cst" -ne 0 ] && { rc=1; break; }
done < "$work/files.tsv"
trap - TERM INT

[ "$rc" != 0 ] && set_err "Download interrupted. Click Download to resume."

# --- install: move into place atomically, drop the Gemma NOTICE beside it ----
# Both offered families are Gemma derivatives, so the mandatory Gemma notice applies to each;
# only the creator credit line differs.
case "$(model_family_of "$name")" in
    milmmt) credit="This model (MiLMMT-46, by Xiaomi, built on Gemma 3) is a Model Derivative distributed under the Gemma Terms of Use." ;;
    *)      credit="This model (TranslateGemma, by Google, built on Gemma 3) is a Model Derivative distributed under the Gemma Terms of Use." ;;
esac
set_state installing
/bin/rm -rf "$dest"
/bin/mv "$staging" "$dest"
mv_rc=$?
if [ "$mv_rc" -eq 0 ]; then
    /bin/cat > "$dest/NOTICE.txt" <<NOTICE
Gemma is provided under and subject to the Gemma Terms of Use found at ai.google.dev/gemma/terms

$credit Your use is also subject to the Gemma Prohibited Use Policy at ai.google.dev/gemma/prohibited_use_policy.

MLX build downloaded from the Hugging Face repository $repo.
NOTICE
    set_state done
else
    set_err "Could not save the model. Click Download to retry."
fi

exit 0
