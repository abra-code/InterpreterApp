# interp.models.load.sh - backgrounded catalog load for the model chooser. Queries the live
# catalog (models.catalog.tsv x Hugging Face), curates it against this Mac's RAM into grouped
# sections (Best Quality / Recommended / Faster), and builds one model CARD per curated row at
# runtime via omc_insert_element. Launched by interp.models.init and interp.models.refresh.
#   args: <chooser_window_uuid>
# Not an OMC command - run directly via /bin/sh.
#
# Perceived latency is handled twice over: a fresh window WARM-STARTS from the previous load's
# cached curation (cards appear immediately, network refresh continues behind them), and after
# the fetch the cards are rebuilt ONLY when the render signature (curated content + install/
# download state) actually changed - an unchanged Refresh repaints nothing, so no flicker.
#
# Card ids derive from the curated row number (interp_card_base_id), so the download/info
# handlers and the download-state poller reverse-map a view id to its curated row without any
# fixed slot table. Inserted card ids are tracked in the chooser's marker dir so a rebuild
# can remove the previous set before inserting the new one.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.models.sh"

window_uuid="$1"
marker="$DOWNLOADS_DIR/.chooser.$window_uuid"

/bin/mkdir -p "$CACHE_DIR" "$marker"

# One load at a time per window: init's load and a Refresh clicked during it (or a fast
# double-Refresh) would otherwise interleave the remove-cards / cards-file / insert-cards
# sequence below - duplicate view ids, orphaned cards. The per-PID cache temps protect the
# DATA files but not the UI mutations, so the whole load is serialized. Losing the click is
# fine: the in-flight load is about to deliver fresh content anyway. The lock dies with the
# window (the marker dir is removed on close), so a hard-killed loader cannot wedge future
# windows.
/bin/mkdir "$marker/rebuild.lock" 2>/dev/null || exit 0
trap '/bin/rmdir "$marker/rebuild.lock" 2>/dev/null' EXIT

# Loading indicator (spinner next to the status text): visible for the whole load, hidden on
# every exit path below.
spinner_done() { "$dialog" "$window_uuid" 911 omc_hide; }
"$dialog" "$window_uuid" 911 omc_show

# The render signature of a curated file: its content plus each row's install/download state.
# Rebuilding only when this changes keeps an unchanged Refresh from flickering, while still
# repainting when a model was installed/removed outside the card poller's view.
render_sig() {   # $1 = curated file
    /bin/cat "$1"
    local _tab=$(/usr/bin/printf '\t') _sec _fam _auth _repo _rest
    while IFS="$_tab" read -r _sec _fam _auth _repo _rest; do
        [ -n "$_repo" ] || continue
        /usr/bin/printf '%s|%s|%s\n' "$_repo" \
            "$([ -f "$MODELS_DIR/$_repo/config.json" ] && echo 1 || echo 0)" \
            "$(/bin/cat "$DOWNLOADS_DIR/$_repo/state" 2>/dev/null)"
    done < "$1"
}

# Remove the tracked card set and their poller dedup sigs, and hide the section boxes.
remove_cards() {
    if [ -f "$marker/cards" ]; then
        while IFS= read -r old_id; do
            case "$old_id" in ''|*[!0-9]*) continue ;; esac
            "$dialog" "$window_uuid" "$old_id" omc_remove_element
        done < "$marker/cards"
    fi
    /bin/rm -f "$marker/cards" "$marker"/row.*.sig
    for sec_box in 1100 1200 1300; do
        "$dialog" "$window_uuid" "$sec_box" omc_hide
    done
}

# Insert one card per curated row of $1 and record the inserted ids + render signature.
# (A poller tick landing between remove_cards' sig clear and a card's insert pushes into a
# not-yet-existent id and is lost; for an active download the advancing percent changes the
# sig and re-pushes within a tick, so only a download stalled at an unchanged percent could
# show a blank line until it moves again - accepted.)
insert_cards() {   # $1 = curated file
    local tab=$(/usr/bin/printf '\t')
    local row=0 seen_best=0 seen_rec=0 seen_fast=0
    local sec fam auth repo label size heavy desc
    local container base installed badge size_text disabled wstate card
    while IFS="$tab" read -r sec fam auth repo label size heavy desc; do
        [ -n "$sec" ] || continue
        row=$((row + 1))
        case "$sec" in
            best)        container=1102; seen_best=1 ;;
            recommended) container=1202; seen_rec=1 ;;
            faster)      container=1302; seen_fast=1 ;;
            *) continue ;;
        esac

        base=$(interp_card_base_id "$row")

        installed=0
        [ -f "$MODELS_DIR/$repo/config.json" ] && installed=1

        badge=""
        if [ "$installed" = 1 ]; then
            badge="Installed"
        elif [ "$heavy" = 1 ]; then
            badge="Heavy"
        fi

        # For a row with an active download, leave the size text AND the button to the download
        # poller (its sig was just cleared, so it re-pushes within a tick); otherwise show the
        # static size line and enable/disable by installed state. The interpolated card fields
        # (label, desc, badge, size_text) are catalog/self-generated and MUST stay free of
        # double quotes and backslashes - models.catalog.tsv authors, keep it that way.
        size_text="$label - $(bytes_to_gb "$size")"
        disabled=false
        wstate=$(/bin/cat "$DOWNLOADS_DIR/$repo/state" 2>/dev/null)
        case "$wstate" in
            preparing|downloading|installing) size_text=""; disabled=true ;;
            *) [ "$installed" = 1 ] && disabled=true ;;
        esac

        card=$(/usr/bin/printf '%s' \
"{\"type\":\"GroupBox\",\"id\":$base,\"properties\":{\"frame\":{\"maxWidth\":\"infinity\"}},\"children\":[\
{\"type\":\"VStack\",\"properties\":{\"alignment\":\"leading\",\"spacing\":6,\"frame\":{\"maxWidth\":\"infinity\"}},\"children\":[\
{\"type\":\"HStack\",\"properties\":{\"spacing\":8},\"children\":[\
{\"type\":\"Text\",\"id\":$((base + 1)),\"properties\":{\"text\":\"$label\",\"font\":\"headline\"}},\
{\"type\":\"Spacer\"},\
{\"type\":\"Text\",\"id\":$((base + 2)),\"properties\":{\"text\":\"$badge\",\"font\":\"caption\"}},\
{\"type\":\"Button\",\"id\":$((base + 6)),\"properties\":{\"systemImage\":\"info.circle\",\"buttonStyle\":\"borderless\",\"help\":\"Model details, source, and license\",\"actionID\":\"interp.models.info\"}}]},\
{\"type\":\"Text\",\"id\":$((base + 3)),\"properties\":{\"text\":\"$desc\",\"font\":\"caption\",\"foregroundStyle\":\"secondary\"}},\
{\"type\":\"HStack\",\"properties\":{\"spacing\":8},\"children\":[\
{\"type\":\"Text\",\"id\":$((base + 4)),\"properties\":{\"text\":\"$size_text\",\"font\":\"caption\",\"foregroundStyle\":\"secondary\"}},\
{\"type\":\"Spacer\"},\
{\"type\":\"Button\",\"id\":$((base + 5)),\"properties\":{\"title\":\"Download\",\"buttonStyle\":\"borderedProminent\",\"actionID\":\"interp.model.download\",\"disabled\":$disabled}}]}]}]}")

        "$dialog" "$window_uuid" "$container" omc_insert_element "$card"
        /usr/bin/printf '%s\n' "$base" >> "$marker/cards"
    done < "$1"

    [ "$seen_best" = 1 ] && "$dialog" "$window_uuid" 1100 omc_show
    [ "$seen_rec" = 1 ]  && "$dialog" "$window_uuid" 1200 omc_show
    [ "$seen_fast" = 1 ] && "$dialog" "$window_uuid" 1300 omc_show

    render_sig "$1" > "$marker/render.sig"
}

# --- warm start: paint the previous load's curation immediately -------------
warm=0
if [ -s "$CACHE_DIR/curated.tsv" ] && [ ! -f "$marker/cards" ]; then
    insert_cards "$CACHE_DIR/curated.tsv"
    warm=1
    "$dialog" "$window_uuid" 910 "Checking for updates…"
fi

# Two overlapping loads (reopen during a load, or a fast double Refresh) share these cache files,
# so build per-process temp files and move them into place atomically - the last writer wins
# cleanly instead of two writers interleaving lines.
cat_tmp="$CACHE_DIR/catalog.$$.tsv"
cur_tmp="$CACHE_DIR/curated.$$.tsv"
/bin/rm -f "$cat_tmp" "$cur_tmp"

interp_fetch_catalog "$cat_tmp"
fetch_rc=$?
if [ "$fetch_rc" -ne 0 ]; then
    /bin/rm -f "$cat_tmp"
    if [ "$warm" = 1 ]; then
        "$dialog" "$window_uuid" 910 "Offline? Showing the last known models."
    else
        "$dialog" "$window_uuid" 910 "Could not reach the model catalog. Check your connection and click Refresh."
    fi
    spinner_done
    exit 0
fi
/bin/mv "$cat_tmp" "$CACHE_DIR/catalog.tsv"

interp_curate_models "$CACHE_DIR/catalog.tsv" > "$cur_tmp"
curate_rc=$?
if [ "$curate_rc" -ne 0 ] || [ ! -s "$cur_tmp" ]; then
    /bin/rm -f "$cur_tmp"
    "$dialog" "$window_uuid" 910 "No suitable model fits this Mac's memory. Click Refresh to try again."
    spinner_done
    exit 0
fi

# Rebuild only when the fresh curation would RENDER differently from what is showing.
# Order matters in the rebuild: remove the OLD cards before swapping curated.tsv, because the
# download poller row-maps curated.tsv onto the live cards every tick - swapping first would
# let a tick overlay the NEW file's rows onto the OLD cards for a sub-second wrong pairing.
if [ -f "$marker/cards" ] && [ -f "$marker/render.sig" ] \
    && render_sig "$cur_tmp" | /usr/bin/cmp -s - "$marker/render.sig"; then
    /bin/rm -f "$cur_tmp"
else
    remove_cards
    /bin/mv "$cur_tmp" "$CACHE_DIR/curated.tsv"
    insert_cards "$CACHE_DIR/curated.tsv"
fi

"$dialog" "$window_uuid" 910 ""
spinner_done

exit 0
