# interp.poll.sh - backgrounded UI poller, one per window. Spawned by interp.window.init (text
# mode) or interp.doc.init (doc mode). Runs until the spool directory disappears (window close /
# app quit), then exits. Not an OMC command - launched directly via /bin/sh.
#   args: <window_uuid> <spool_dir> [mode]   mode = text (default) | doc | transform | transform-doc
#
# This poller OWNS the mlx-agent map broker. Each tick it:
#   1. syncs the Model picker + a `modelpaths` index to whatever is installed under Models/,
#      auto-selecting a model when none is chosen yet (first-run pickup after a download);
#   2. moves a queued job along (advance_job, lib.interp.load.sh): it waits for this window's
#      turn in the app-wide queue, then for room in memory (other windows' idle models are
#      unloaded), then for the model to load, and is handed to the broker last;
#   3. keeps at most one broker running for the selected model. A broker is spawned only for a
#      job (load.wanted), never because the window opened or a model was selected; one that is
#      running is kept until the selection changes, the window closes, or another window's job
#      needs the memory (spool/evicted);
#   4. reflects the broker's status.json (-> status line + button state) and result.txt into the
#      window: text mode pushes into the target editor; doc mode writes the finished translation
#      to the chosen output file and points the output QuickLook at it;
#   5. leaves the queue when the job is over (release_finished_job).
# Single ownership here is what lets first-run and model switching work without the init or the
# switch handler managing broker processes. The two windows share this one poller; only the swap
# button (text-only) and the result delivery differ by mode.
#
# transform mode (the Text Transform window): the model list is the installed transformers of
# every family the selected transform runs on (spool/preset.file, written by
# interp.transform.init and interp.transform.preset.changed), the preset follows the selected
# model to the transform's variant for its family, the broker is keyed on model AND preset
# (sampling is per broker process), there are no language pickers, and a finished run gets a fact
# check (transform_check) shown under the result.
#
# transform-doc mode (the Text Transform document window) is transform mode with document mode's
# delivery: the finished result is written to the output file instead of the right-hand editor.
# The two properties are tracked separately (IS_TRANSFORM, IS_DOC) so each check asks only the
# question it means.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"

window_uuid="$1"       # override the (inherited) uuid with the explicit arg
spool="$2"
MODE="${3:-text}"      # text | doc | transform | transform-doc
case "$MODE" in transform|transform-doc) IS_TRANSFORM=1 ;; *) IS_TRANSFORM=0 ;; esac
case "$MODE" in doc|transform-doc)       IS_DOC=1 ;;       *) IS_DOC=0 ;; esac

if [ "$IS_TRANSFORM" = 1 ]; then
    source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.transform.sh"
    VERB_ING="Rewriting"; VERB_PAST="rewritten"
    SAVED_MODEL_KEY="TransformModelName"
    NO_MODEL_TEXT="No model for this transform. Choose \"Download models...\" from the Model menu."
    DOWNLOAD_OPTION="Download models..."
else
    VERB_ING="Translating"; VERB_PAST="translated"
    BUTTON_NAME="Translate"
    SAVED_MODEL_KEY="ModelName"
    NO_MODEL_TEXT="No translation model. Choose \"Download models…\" from the Model menu."
    DOWNLOAD_OPTION="Download models…"
fi
LAST_CHECK_EPOCH=""       # transform mode: epoch whose finished result was already checked

# Transform mode: the model families the window's transform runs on (every variant's), space
# separated, and the words its status line uses ("Summarizing", "summarized"). Listing the
# families reads every preset file, so this is redone only when the preset changes.
GROUP_PRESET="__unset__"
GROUP_FAMS=""
sync_group() {
    [ "$IS_TRANSFORM" = 1 ] || return 0
    local _preset="$(/bin/cat "$spool/preset.file" 2>/dev/null)"
    [ "$_preset" = "$GROUP_PRESET" ] && return 0
    GROUP_PRESET="$_preset"
    GROUP_FAMS="$(preset_families "$_preset" | /usr/bin/tr '\n' ' ')"
    VERB_ING="$(transform_status_working "$_preset")"
    VERB_PAST="$(transform_status_done "$_preset")"
    BUTTON_NAME="$(preset_get "$_preset" button)"
    [ -n "$BUTTON_NAME" ] || BUTTON_NAME="Run"
}

# The queue label of this window's job, for the poller's own enqueue (advance_job).
window_job_label() {
    local _m="$(/bin/cat "$spool/model.dir" 2>/dev/null)"
    if [ "$IS_TRANSFORM" = 1 ]; then
        transform_job_label "$(/bin/cat "$spool/job.preset" 2>/dev/null)" "$_m"
    else
        translation_job_label "$_m"
    fi
}

# The installed models this window can pick from, one resolved path per line, and their labels.
# The transform list carries the transform's families on its first line, so a preset switch to
# other families changes the signature sync_models compares and rebuilds the picker.
window_model_list() {
    if [ "$IS_TRANSFORM" = 1 ]; then
        local _fam
        /usr/bin/printf '#%s\n' "$GROUP_FAMS"
        for _fam in $GROUP_FAMS; do
            list_transform_dirs "$_fam"
        done
    else
        list_model_dirs
    fi
}
window_model_label() {   # $1 = model dir
    if [ "$IS_TRANSFORM" = 1 ]; then transform_display_label "$1"; else model_display_label "$1"; fi
}
# What the running broker must match: the model, plus the preset in transform mode.
broker_key() {   # $1 = selected model dir
    if [ "$IS_TRANSFORM" = 1 ]; then
        /usr/bin/printf '%s|%s' "$1" "$(/bin/cat "$spool/preset.file" 2>/dev/null)"
    else
        /usr/bin/printf '%s' "$1"
    fi
}

# The document window has no Swap control; make swap toggles no-ops there so the shared status
# logic below can call them unconditionally.
enable_swap()  { [ "$MODE" = text ] && enable_ctrl "$SWAP_BTN"; }
disable_swap() { [ "$MODE" = text ] && disable_ctrl "$SWAP_BTN"; }
# The run button and Estimate Time are on and off together: either one queues a request.
enable_run()  { enable_ctrl "$TRANSLATE_BTN"; enable_ctrl "$ESTIMATE_BTN"; }
disable_run() { disable_ctrl "$TRANSLATE_BTN"; disable_ctrl "$ESTIMATE_BTN"; }

# " (about 25s)" for the idle line, when the model's load time was measured on this Mac.
idle_load_note() {   # $1 = model folder
    [ -n "$1" ] || return 0
    local _s="$(speed_get model "$(/usr/bin/basename "$1")" 4)"
    case "$_s" in ''|*[!0-9]*) return 0 ;; esac
    /usr/bin/printf ' (about %s)' "$(format_duration "$_s")"
}

# A request of this window waits in the queue: a job (job.next.json) or an Estimate Time request
# for a model never measured here (estimate.next). Both wait, make room and load the same way.
request_queued() { [ -f "$spool/job.next.json" ] || [ -f "$spool/estimate.next" ]; }

# Cross-tick state (globals, UPPERCASE) mutated by the functions below.
LAST_MODELS="__unset__"   # signature of the installed-model set (rebuild the picker on change).
                          # NOT "" - that is the real signature for "zero models", and the
                          # chooser's Done-without-download path must still build the picker.
LAST_UI_SIG=""            # coarse UI signature (state + progress + label) to avoid redundant writes
LAST_RESULT_SIG=""        # mtime+size of result.txt
LAST_SHOWN_SEL=""         # model dir the Model picker was last set to show

# --- keep the Model picker in sync with what is installed -------------------
sync_models() {
    local _list="$(window_model_list)"
    if [ "$_list" = "$LAST_MODELS" ]; then
        # Transform mode: a transform switch can move the model without changing the list (two
        # transforms on one family, each back on the model last picked for it, see
        # select_transform), so a moved selection is shown here too.
        local _cur="$(/bin/cat "$spool/model.dir" 2>/dev/null)"
        if [ "$IS_TRANSFORM" = 1 ] && [ -n "$_cur" ] && [ "$_cur" != "$LAST_SHOWN_SEL" ]; then
            local _ri="$(/usr/bin/grep -Fxn "$_cur" "$spool/modelpaths" 2>/dev/null | /usr/bin/head -1 | /usr/bin/cut -d: -f1)"
            case "$_ri" in ''|*[!0-9]*) return 0 ;; esac
            LAST_SHOWN_SEL="$_cur"
            "$dialog" "$window_uuid" "$MODEL_PICKER" "$_ri"
        fi
        return 0
    fi
    LAST_MODELS="$_list"

    local _opts="[" _first=1 _oldifs="$IFS" _m _lbl
    : > "$spool/modelpaths.tmp"
    IFS='
'
    for _m in $_list; do
        [ -n "$_m" ] || continue
        case "$_m" in '#'*) continue ;; esac
        _lbl="$(window_model_label "$_m")"
        if [ "$_first" = 1 ]; then _first=0; else _opts="$_opts,"; fi
        _opts="$_opts\"$_lbl\""
        /usr/bin/printf '%s\n' "$_m" >> "$spool/modelpaths.tmp"
    done
    IFS="$_oldifs"
    if [ "$_first" = 1 ]; then _opts="$_opts\"$DOWNLOAD_OPTION\""; else _opts="$_opts,\"$DOWNLOAD_OPTION\""; fi
    _opts="$_opts]"
    /bin/mv "$spool/modelpaths.tmp" "$spool/modelpaths"

    # Programmatic option/value updates can fire interp.model.changed with a transitional value
    # (an OMC Picker caveat). Mark a short quiet window so that handler ignores those echoes and
    # does not spuriously switch models or open the chooser.
    local _now="$(/bin/date +%s)"
    /usr/bin/printf '%s' "$(( _now + 2 ))" > "$spool/picker_quiet"
    "$dialog" "$window_uuid" "$MODEL_PICKER" omc_set_property "options" "$_opts"

    # Auto-select: if nothing is chosen yet, or the chosen model is gone, restore the SAVED
    # last-used model (defaults ModelName, written by interp.model.changed on a genuine user
    # pick; matched by directory basename), falling back to the first installed one. This is
    # the window-open / first-run / post-download pickup path. Selecting a model loads nothing:
    # the broker is spawned for a job only. (Two windows on the same MLX model do NOT share its
    # weights - each mlx-agent copies them into its own GPU buffers - which is why other
    # windows' idle models are unloaded before a load that would not fit, lib.interp.load.sh.)
    local _sel="$(/bin/cat "$spool/model.dir" 2>/dev/null)"
    local _sel_known=0
    [ -n "$_sel" ] && /usr/bin/grep -Fxq "$_sel" "$spool/modelpaths" 2>/dev/null && _sel_known=1
    if [ "$_sel_known" = 0 ]; then
        local _saved="$("$defaults_tool" read "$BUNDLE_ID" "$SAVED_MODEL_KEY" 2>/dev/null)"
        _sel=""
        [ -n "$_saved" ] && _sel="$(/usr/bin/awk -F/ -v n="$_saved" '$NF==n { print; exit }' "$spool/modelpaths" 2>/dev/null)"
        [ -n "$_sel" ] || _sel="$(/usr/bin/head -1 "$spool/modelpaths" 2>/dev/null)"
        if [ -n "$_sel" ]; then
            /usr/bin/printf '%s' "$_sel" > "$spool/model.dir.tmp" && /bin/mv "$spool/model.dir.tmp" "$spool/model.dir"
        else
            /bin/rm -f "$spool/model.dir"
        fi
    fi

    # Reflect the selected model as the picker's 1-based selection (idempotent for the handler).
    LAST_SHOWN_SEL="$_sel"
    if [ -n "$_sel" ]; then
        local _ci="$(/usr/bin/grep -Fxn "$_sel" "$spool/modelpaths" 2>/dev/null | /usr/bin/head -1 | /usr/bin/cut -d: -f1)"
        case "$_ci" in ''|*[!0-9]*) _ci=1 ;; esac
        "$dialog" "$window_uuid" "$MODEL_PICKER" "$_ci"
    fi
}

# Transform mode: when the selected model is of another family than the window's preset (the
# window opened, or a download landed, on a model of the transform's other family), switch to the
# variant made for it. Looked at only when the model or the preset changed since the last tick.
LAST_VARIANT_KEY=""
sync_variant() {
    [ "$IS_TRANSFORM" = 1 ] || return 0
    local _key="$(/bin/cat "$spool/model.dir" 2>/dev/null)|$(/bin/cat "$spool/preset.file" 2>/dev/null)"
    [ "$_key" = "$LAST_VARIANT_KEY" ] && return 0
    LAST_VARIANT_KEY="$_key"
    sync_preset_variant "$spool"
}

# --- keep the language pickers matched to the selected model's family --------
# populate_language_pickers records the family it populated for (spool/langfamily). When a
# model switch (user pick, post-download auto-pickup) lands on a DIFFERENT family, re-populate
# so the pickers only offer languages the new model supports. Selections survive by saved code;
# a code the new family lacks falls back inside the populate (From to Detect language, To to es).
sync_languages() {
    [ "$IS_TRANSFORM" = 1 ] && return 0
    local _fam=$(model_family_of "$(/bin/cat "$spool/model.dir" 2>/dev/null)")
    [ "$_fam" = "$(/bin/cat "$spool/langfamily" 2>/dev/null)" ] && return 0
    populate_language_pickers "$spool"
    # That fallback can land the To picker on a different language, and in document mode the
    # output file is named after it - so the destination follows the picker here too.
    if [ "$MODE" = doc ]; then
        refresh_doc_output "$spool" "$(/bin/cat "$spool/to.code" 2>/dev/null)"
    fi
}

# Stop this window's broker (its llama-server follows via the watchdog) and clear its state files.
retire_broker() {
    [ -f "$spool/broker.pid" ] || return 0
    local _bpid="$(/bin/cat "$spool/broker.pid" 2>/dev/null)"
    pid_alive "$_bpid" && kill_broker_pid "$_bpid"
    /bin/rm -f "$spool/broker.pid" "$spool/broker.model" "$spool/status.json" "$spool/result.txt" \
               "$spool/job.json" "$spool/translate.start" "$spool/translate.elapsed"
    LAST_UI_SIG=""
}

# --- ensure one broker is running for the selected model --------------------
ensure_broker() {
    local _sel="$(/bin/cat "$spool/model.dir" 2>/dev/null)"
    if [ -z "$_sel" ] || [ ! -d "$_sel" ]; then
        # Transform mode: a preset switch to a family with nothing installed leaves no selection
        # while the previous preset's broker is still up and "ready" - retire it, so the window
        # shows "no model" instead of offering a run on the wrong model.
        [ "$IS_TRANSFORM" = 1 ] && retire_broker
        return 0        # no model yet; the UI phase handling reports it
    fi
    local _key="$(broker_key "$_sel")"

    # This model could not be loaded (see note_load_failure in lib.interp.sh): stay down, and let
    # reflect_ui show why, until the selection or the model's folder changes.
    if load_failed_for "$spool" "$_key" "$_sel"; then
        return 0
    fi

    if [ -f "$spool/broker.pid" ]; then
        local _bpid="$(/bin/cat "$spool/broker.pid" 2>/dev/null)"
        local _bmodel="$(/bin/cat "$spool/broker.model" 2>/dev/null)"
        if pid_alive "$_bpid"; then
            if [ "$_bmodel" = "$_key" ]; then       # correct broker already running
                # Loaded once: a later crash gets its retries afresh.
                if [ -f "$spool/load.attempts" ]; then
                    broker_never_loaded "$spool" || /bin/rm -f "$spool/load.attempts"
                fi
                # Still loading, and nothing waits for it any more (Stop withdrew the queued job):
                # do not let it take the memory for nothing. Not one in "error": that is a failed
                # idle reload, which holds no model and whose message the window must keep
                # showing (advance_job retires it when the next job comes).
                if [ ! -f "$spool/load.wanted" ] && ! request_queued \
                    && ! job_active "$spool" && broker_never_loaded "$spool"; then
                    local _bstate="$("$plutil" -extract state raw -o - "$spool/status.json" 2>/dev/null)"
                    if [ "$_bstate" != error ]; then
                        retire_broker
                        /bin/rm -f "$spool/load.attempts"
                    fi
                fi
                return 0
            fi
            /bin/rm -f "$spool/load.attempts"
            kill_broker_pid "$_bpid"                 # model switched: retire the old broker
            # Wait for it to release its model weights before loading the new one, so a switch
            # never momentarily holds two models in memory. Escalate to SIGKILL if it does not go
            # after the graceful window; if it STILL will not die, defer the respawn to a later
            # tick rather than spawning a second broker against the same spool.
            local _w=0
            while pid_alive "$_bpid" && [ "$_w" -lt 30 ]; do /bin/sleep 0.2; _w=$(( _w + 1 )); done
            if pid_alive "$_bpid"; then
                local _a="$(/bin/ps -p "$_bpid" -o args= 2>/dev/null)"
                case "$_a" in "$AGENT_BIN"|"$AGENT_BIN "*) /bin/kill -KILL "$_bpid" 2>/dev/null ;; esac
                _w=0
                while pid_alive "$_bpid" && [ "$_w" -lt 15 ]; do /bin/sleep 0.2; _w=$(( _w + 1 )); done
                pid_alive "$_bpid" && return 0        # still alive: try again next tick
            fi
        elif [ "$_bmodel" = "$_key" ] && broker_never_loaded "$spool"; then
            # The broker for this very model ended before it ever loaded it: it could not load
            # the model. Try once more, then give up and say why (reflect_ui).
            if note_load_failure "$spool" "$_key" "$_sel" "$_bpid"; then
                # load.failed has the reason now; the dead broker's status would only show again
                # once the record lifts.
                /bin/rm -f "$spool/broker.pid" "$spool/broker.model" "$spool/status.json"
                LAST_UI_SIG=""
                return 0
            fi
        else
            /bin/rm -f "$spool/load.attempts"     # another model's broker, or one that had loaded
            # It died in the middle of a job (a crash: an unload for another window only ever
            # takes an idle broker). The job goes with the cleanup below, so say so rather than
            # fall back to a plain "Ready".
            if [ "$_bmodel" = "$_key" ] && [ -f "$spool/job.json" ]; then
                case "$("$plutil" -extract state raw -o - "$spool/status.json" 2>/dev/null)" in
                    done|cancelled|error) ;;
                    *) /usr/bin/printf '%s' "The model stopped during the job. Click $BUTTON_NAME to try again." \
                           > "$spool/job.notice" ;;
                esac
            fi
        fi
        /bin/rm -f "$spool/broker.pid" "$spool/broker.model"
        # Clear the previous broker's status/result AND the previous translation's timing so the
        # switched-to model starts clean - otherwise its first idle "ready" would show a stale
        # "(translated in Xs)" from the model we just left.
        /bin/rm -f "$spool/status.json" "$spool/result.txt" "$spool/job.json" \
                   "$spool/translate.start" "$spool/translate.elapsed"
    fi

    # No broker is running for the selection. Load only for a job whose turn it is (advance_job
    # wrote load.wanted after making room): opening a window or picking a model loads nothing.
    # The request is checked too: Stop may have withdrawn it since advance_job looked.
    [ -f "$spool/load.wanted" ] && request_queued || return 0

    /bin/rm -f "$spool/evicted"
    # When it started, for the load time learn_speed records.
    /usr/bin/printf '%s' "$(/bin/date +%s)" > "$spool/broker.spawned"
    disable_run; disable_swap
    # Where this broker's lines start in agent.log, for load_failure_reason.
    /usr/bin/stat -f '%z' "$spool/agent.log" > "$spool/broker.logstart" 2>/dev/null \
        || /usr/bin/printf '0' > "$spool/broker.logstart"
    local _npid
    if [ "$IS_TRANSFORM" = 1 ]; then
        _npid="$(spawn_transform_broker "$spool" "$_sel" "$(/bin/cat "$spool/preset.file" 2>/dev/null)")"
    else
        _npid="$(spawn_broker "$spool" "$_sel")"
    fi
    /usr/bin/printf '%s' "$_npid" > "$spool/broker.pid"
    /usr/bin/printf '%s' "$(broker_key "$_sel")" > "$spool/broker.model"
    LAST_UI_SIG=""      # force a fresh status render for the new broker
}

# --- the queued job (lib.interp.load.sh) ------------------------------------
# A job the handler queued (job.next.json) waits for this window's turn, then for room in memory,
# then for the model to load, and is handed to the broker (renamed to job.json) only once the
# model is loaded. Handing it over earlier would lose it: a broker that fails to load is
# respawned on a cleaned spool, and mlx-agent clears a stop flag when it starts a job, so a Stop
# during the load would be lost too.
advance_job() {
    # No queued job: a load.wanted left now is stale (a Stop withdrew the job while this poller was
    # making room, then the poller wrote it). Left in place, ensure_broker would load for nothing,
    # and load again whenever another window unloaded the model.
    if ! request_queued; then
        /bin/rm -f "$spool/load.wanted"
        return 0
    fi
    local _req="$spool/job.next.json"
    [ -f "$_req" ] || _req="$spool/estimate.next"
    if [ ! -f "$spool/queue.entry" ]; then
        # The handler enqueues right after it writes the job. An entry still missing seconds
        # later means it never did (killed in between): queue the job from here.
        local _mt="$(/usr/bin/stat -f '%m' "$_req" 2>/dev/null)"
        case "$_mt" in ''|*[!0-9]*) return 0 ;; esac
        [ $(( $(/bin/date +%s) - _mt )) -ge 5 ] || return 0
        queue_enqueue "$spool" "$(window_job_label)"
    fi
    queue_is_head "$spool" || return 0

    # The job was built for the model (and transform) selected when it was queued. A raw-prompt
    # family must not get a chat job, nor a preset's job run on another preset's broker.
    local _sel="$(/bin/cat "$spool/model.dir" 2>/dev/null)"
    if [ "$(/bin/cat "$spool/job.next.model" 2>/dev/null)" != "$_sel" ]; then
        withdraw_queued_job "$spool" "The model changed while the job was waiting. Click $BUTTON_NAME again."
        LAST_UI_SIG=""
        return 0
    fi
    if [ "$IS_TRANSFORM" = 1 ] && [ -f "$spool/job.next.json" ] \
        && [ "$(/bin/cat "$spool/job.preset" 2>/dev/null)" != "$(/bin/cat "$spool/preset.file" 2>/dev/null)" ]; then
        withdraw_queued_job "$spool" "The transform changed while the job was waiting. Click $BUTTON_NAME again."
        LAST_UI_SIG=""
        return 0
    fi
    [ -n "$_sel" ] && [ -d "$_sel" ] || return 0
    local _key="$(broker_key "$_sel")"
    if load_failed_for "$spool" "$_key" "$_sel"; then
        withdraw_queued_job "$spool"      # reflect_ui says why the model could not load
        LAST_UI_SIG=""
        return 0
    fi

    # This window's turn: make room for the model once, then ask ensure_broker to load it.
    if [ "$(/bin/cat "$spool/load.wanted" 2>/dev/null)" != "$_key" ]; then
        make_room_for "$spool" "$_sel"
        /usr/bin/printf '%s' "$_key" > "$spool/load.wanted"
        LAST_UI_SIG=""
    fi

    local _bpid="$(/bin/cat "$spool/broker.pid" 2>/dev/null)"
    pid_alive "$_bpid" || return 0
    [ "$(/bin/cat "$spool/broker.model" 2>/dev/null)" = "$_key" ] || return 0
    if broker_never_loaded "$spool"; then
        # An idle-unloaded broker that then failed to reload stays alive in that error and would
        # never take the job: retire it, so ensure_broker loads afresh (with its retry count).
        if [ "$("$plutil" -extract state raw -o - "$spool/status.json" 2>/dev/null)" = error ]; then
            retire_broker
        fi
        return 0
    fi

    # Loaded, for an Estimate Time request: answer it from what the load measured (learn_speed
    # ran earlier in this tick), and leave the model loaded for the job that likely follows. The
    # rename fails when Stop withdrew the request a moment ago.
    if [ ! -f "$spool/job.next.json" ]; then
        /bin/mv "$spool/estimate.next" "$spool/estimate.answering" 2>/dev/null || return 0
        local _chars="$(/bin/cat "$spool/estimate.answering" 2>/dev/null)"
        /bin/rm -f "$spool/estimate.answering" "$spool/job.next.model" "$spool/load.wanted"
        # The load ended after learn_speed's copy of status.json in this tick: record it first.
        [ -f "$spool/broker.spawned" ] && learn_speed
        local _answer="$(estimate_sentence "$_chars" "$_sel" "$(job_speed_key "$spool" "$_sel")" 1)"
        [ -n "$_answer" ] || _answer="The model is loaded. Its speed is measured during the first run, so there is no estimate yet."
        /usr/bin/printf '%s' "$_answer" > "$spool/job.notice"
        /bin/rm -f "$spool/evicted"
        LAST_UI_SIG=""
        return 0
    fi

    # Loaded: hand the job over. The rename fails when Stop withdrew the job a moment ago. The
    # timing starts here, so the elapsed time shown at "done" is the job's own.
    /bin/mv "$spool/job.next.json" "$spool/job.json" 2>/dev/null || return 0
    /bin/rm -f "$spool/job.next.model" "$spool/load.wanted" "$spool/translate.elapsed"
    /usr/bin/perl -MTime::HiRes=time -e 'printf "%.3f", time' > "$spool/translate.start" 2>/dev/null
    LAST_UI_SIG=""
}

# Remember what a load and a finished job measured (Speeds.tsv, lib.interp.load.sh), for the
# Estimate Time button. Runs before advance_job, which answers an estimate request from it, and
# before reflect_ui, which spends the job's timing stamp (translate.start) on the "done" line.
LEARNED_EPOCH=""
# The running job's timing stamp, kept from the ticks before "done": a job that finishes between
# this function's copy of status.json and reflect_ui's has its stamp spent by reflect_ui first.
LEARN_START=""
learn_speed() {
    local _stamp="$(/bin/cat "$spool/translate.start" 2>/dev/null)"
    [ -n "$_stamp" ] && LEARN_START="$_stamp"
    [ -f "$spool/status.json" ] || return 0
    local _model="$(/bin/cat "$spool/broker.model" 2>/dev/null)"
    _model="${_model%%|*}"
    [ -n "$_model" ] || return 0
    local _snap="$spool/status.learn.json"
    /bin/cp "$spool/status.json" "$_snap" 2>/dev/null || return 0
    local _st="$("$plutil" -extract state raw -o - "$_snap" 2>/dev/null)"
    local _tps="$("$plutil" -extract tok_per_sec raw -o - "$_snap" 2>/dev/null)"

    # The first state after "loading" of a broker this poller spawned: the load is over.
    if [ -f "$spool/broker.spawned" ]; then
        case "$_st" in
            ready|mapping|done|cancelled)
                local _t0="$(/bin/cat "$spool/broker.spawned" 2>/dev/null)"
                case "$_t0" in
                    ''|*[!0-9]*) ;;
                    *) learn_model_load "$_model" "$(( $(/bin/date +%s) - _t0 ))" "$_tps" ;;
                esac
                /bin/rm -f "$spool/broker.spawned" ;;
            error) /bin/rm -f "$spool/broker.spawned" ;;
        esac
    fi

    # This job finished: its time per character.
    [ "$_st" = done ] || return 0
    local _ep="$("$plutil" -extract epoch raw -o - "$_snap" 2>/dev/null)"
    local _jep="$("$plutil" -extract epoch raw -o - "$spool/job.json" 2>/dev/null)"
    [ -n "$_ep" ] && [ "$_ep" = "$_jep" ] && [ "$_ep" != "$LEARNED_EPOCH" ] || return 0
    LEARNED_EPOCH="$_ep"
    local _start="$LEARN_START"
    LEARN_START=""
    [ -n "$_start" ] || return 0
    local _secs="$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.3f", time - $ARGV[0]' "$_start" 2>/dev/null)"
    local _chars="$(LC_ALL=en_US.UTF-8 /usr/bin/wc -m < "$spool/source.$_ep.txt" 2>/dev/null | /usr/bin/tr -d ' ')"
    learn_job "$_model" "$(job_speed_key "$spool" "$_model")" "$_secs" "$_chars" "$_tps"
}

# Leave the queue once the job is over (done, cancelled, failed, or its broker died), so the next
# window's job can start.
release_finished_job() {
    # The entry is read FIRST and only that one is released: a Translate clicked in the meantime
    # writes a new job and a new entry, which must not go with the old job's release.
    local _entry="$(/bin/cat "$spool/queue.entry" 2>/dev/null)"
    [ -n "$_entry" ] || return 0
    request_queued && return 0
    job_active "$spool" && return 0
    [ "$(/bin/cat "$spool/queue.entry" 2>/dev/null)" = "$_entry" ] || return 0
    queue_release "$spool"
}

# --- reflect broker status into the window ----------------------------------
reflect_ui() {
    local _sel="$(/bin/cat "$spool/model.dir" 2>/dev/null)"

    # Every field comes from ONE copy of status.json. Read field by field from the live file, the
    # state could be the previous job's "done" and the epoch already the next job's (the broker
    # takes a handed-over job within 150 ms): the job would then look finished the moment it
    # started, and its timing stamp would be spent on that.
    local _state="" _chunk="" _total="" _msg="" _tps="" _eta="" _sepoch=""
    local _snap="$spool/status.snap.json"
    /bin/rm -f "$_snap"
    [ -f "$spool/status.json" ] && /bin/cp "$spool/status.json" "$_snap" 2>/dev/null
    if [ -f "$_snap" ]; then
        _state=$("$plutil" -extract state raw -o - "$_snap" 2>/dev/null)
        _chunk=$("$plutil" -extract chunk raw -o - "$_snap" 2>/dev/null)
        _total=$("$plutil" -extract total raw -o - "$_snap" 2>/dev/null)
        _msg=$("$plutil" -extract message raw -o - "$_snap" 2>/dev/null)
        _tps=$("$plutil" -extract tok_per_sec raw -o - "$_snap" 2>/dev/null)
        _eta=$("$plutil" -extract eta_sec raw -o - "$_snap" 2>/dev/null)
        _sepoch=$("$plutil" -extract epoch raw -o - "$_snap" 2>/dev/null)
    fi
    # Synthesize a phase for the pre-status.json window: no model, broker warming up, or no broker
    # at all - the usual state of a window until its first job (idle: the model loads on demand).
    local _broker_up=0
    pid_alive "$(/bin/cat "$spool/broker.pid" 2>/dev/null)" && _broker_up=1
    if [ -z "$_state" ]; then
        if [ -z "$_sel" ]; then _state="nomodel"
        elif [ "$_broker_up" = 1 ]; then _state="loading"
        else _state="idle"; fi
    fi
    # Transform mode: a preset or model switch turns Rewrite off from its handler, which this
    # signature cannot see. The handler leaves ui.stale AFTER recording the switch: forget the
    # signature so the button is re-rendered even when the switch was undone before this tick
    # (A -> B -> A keeps the same broker, and the button would otherwise stay off). A broker that
    # does not match the recorded selection yet is about to be respawned - show it as loading, so
    # Rewrite is never re-enabled against it.
    if [ "$IS_TRANSFORM" = 1 ]; then
        [ -f "$spool/ui.stale" ] && { /bin/rm -f "$spool/ui.stale"; LAST_UI_SIG=""; }
        [ -n "$_sel" ] && [ "$_broker_up" = 1 ] \
            && [ "$(/bin/cat "$spool/broker.model" 2>/dev/null)" != "$(broker_key "$_sel")" ] \
            && _state="loading"
    fi
    # The selected model could not be loaded (ensure_broker gave up on it, and has just cleared
    # the record if the selection or the folder changed since).
    if [ -n "$_sel" ] && [ -f "$spool/load.failed" ]; then
        _state="loadfailed"
        _msg="$(/usr/bin/sed -n 2p "$spool/load.failed" 2>/dev/null)"
    fi

    # A queued job (lib.interp.load.sh): waiting for other windows' jobs (queued; _msg names the
    # first of them), or for its own model to load (pending). A job just handed over, whose broker
    # still reports the previous job, is shown as started rather than as that job's end.
    local _qn=0
    if request_queued && [ "$_state" != loadfailed ]; then
        local _ahead="$(queue_ahead_of "$spool")"
        if [ -f "$spool/queue.entry" ] && [ -z "$_ahead" ]; then
            _state="pending"
        else
            _state="queued"
            _qn="$(/usr/bin/printf '%s\n' "$_ahead" | /usr/bin/grep -c .)"
            _msg="$(queue_entry_label "$(/usr/bin/printf '%s\n' "$_ahead" | /usr/bin/head -1)")"
        fi
    elif [ -f "$spool/job.json" ]; then
        case "$_state" in ready|done|cancelled|error)
            local _jep="$("$plutil" -extract epoch raw -o - "$spool/job.json" 2>/dev/null)"
            [ -n "$_jep" ] && [ "$_jep" != "$_sepoch" ] && job_active "$spool" && _state="starting" ;;
        esac
    fi
    # A job withdrawn before it ran (Stop, or a switch while it waited) says so until the next
    # job, over the idle line or the last run's "Ready". Idle also says when the model was
    # unloaded for another window, which is more than "loads on demand".
    local _notice=""
    case "$_state" in idle|ready|done|cancelled)
        [ -f "$spool/job.notice" ] && _notice="$(/bin/cat "$spool/job.notice" 2>/dev/null)" ;;
    esac
    if [ "$_state" = idle ] && [ -z "$_notice" ] && [ -f "$spool/evicted" ]; then
        _msg="The model was unloaded to make room for another window's job. It loads again when you click $BUTTON_NAME."
    fi

    local _sig="$_state|$_chunk|$_total|$_msg|$_tps|$_eta|$_qn|$_notice"
    [ "$_sig" = "$LAST_UI_SIG" ] && return 0
    LAST_UI_SIG="$_sig"

    # A source language found by Detect language ("from Polish"), written by the Translate handler
    # before it published the job and removed for a job whose From language was chosen.
    local _from_note=""
    if [ "$IS_TRANSFORM" != 1 ] && [ -f "$spool/from.detected" ]; then
        _from_note=" from $(/bin/cat "$spool/from.detected" 2>/dev/null)"
        [ "$_from_note" = " from " ] && _from_note=""
    fi

    # Display helpers: tok/s as an integer, ETA seconds as "24s" / "1m 20s".
    local _tpsN=""
    case "$_tps" in ''|*[!0-9.]*) : ;; *) _tpsN=$(/usr/bin/awk -v x="$_tps" 'BEGIN{ printf "%.0f", x }') ;; esac
    # ETA phrase: "almost done" for the last few seconds (a specific tiny number reads badly and
    # the estimate runs low near the end anyway - and "about a few seconds" would compound two
    # vague terms), otherwise "about <Ns / Xm SSs> left".
    local _etaTxt=""
    case "$_eta" in
        ''|*[!0-9]*) : ;;
        *) if [ "$_eta" -le 5 ]; then
               _etaTxt="almost done"
           else
               _etaTxt="about $(/usr/bin/awk -v s="$_eta" 'BEGIN{
                   if (s < 60) printf "%ds", s; else printf "%dm %02ds", int(s/60), s%60 }') left"
           fi ;;
    esac

    # Idle (ready/done/cancelled/error): Translate + Clear + Swap enabled, Stop off. Busy
    # (nomodel/loading/mapping): those off; Stop on only while mapping. Clear and Swap are kept
    # off during a job so they cannot race the per-chunk result writes reflected into the pane.
    local _es _cn _tn _cur _st _nw
    case "$_state" in
        nomodel)
            disable_run; disable_swap; disable_ctrl "$STOP_BTN"
            set_status "$NO_MODEL_TEXT" ;;
        idle)
            enable_run; enable_swap; disable_ctrl "$STOP_BTN"
            set_status "${_msg:-Ready. The model loads when you click $BUTTON_NAME$(idle_load_note "$_sel").}" ;;
        queued)
            disable_run; disable_swap; enable_ctrl "$STOP_BTN"
            if [ "$_qn" -gt 1 ]; then
                set_status "Waiting for $_qn jobs in other windows to finish, first: ${_msg}…"
            elif [ -n "$_msg" ]; then
                set_status "Waiting for another window to finish: ${_msg}…"
            else
                set_status "Waiting for another window to finish…"
            fi ;;
        pending)
            disable_run; disable_swap; enable_ctrl "$STOP_BTN"
            if [ -f "$spool/job.next.json" ]; then set_status "Loading model…"
            else set_status "Loading the model to measure its speed…"; fi ;;
        starting)
            disable_run; disable_swap; enable_ctrl "$STOP_BTN"
            set_status "$VERB_ING$_from_note…" ;;
        loading)
            disable_run; disable_swap; disable_ctrl "$STOP_BTN"
            set_status "Loading model…" ;;
        loadfailed)
            disable_run; disable_swap; disable_ctrl "$STOP_BTN"
            set_status "Could not load this model: ${_msg:-it stopped while loading}. Choose another model, or delete it and download it again." ;;
        ready)
            enable_run; enable_swap; disable_ctrl "$STOP_BTN"
            # Fresh post-load state: show the model's measured speed so it can be compared.
            if [ -n "$_tpsN" ]; then set_status "Ready — $_tpsN tok/s"
            else set_status "Ready"; fi ;;
        mapping)
            disable_run; disable_swap; enable_ctrl "$STOP_BTN"
            # status.json `chunk` is a COMPLETED count (0..total); the chunk being worked on is
            # completed+1. Show that as a human 1-based "chunk N of M", capped at M, and only when
            # there is more than one chunk (a single chunk needs no counter).
            _cn="$_chunk"; case "$_cn" in ''|*[!0-9]*) _cn=0 ;; esac
            _tn="$_total"; case "$_tn" in ''|*[!0-9]*) _tn=0 ;; esac
            local _base _tail=""
            if [ "$_tn" -ge 2 ]; then
                _cur=$(( _cn + 1 )); [ "$_cur" -gt "$_tn" ] && _cur="$_tn"
                _base="$VERB_ING$_from_note, chunk $_cur of $_tn"
                [ -n "$_from_note" ] || _base="$VERB_ING chunk $_cur of $_tn"
            else
                _base="$VERB_ING$_from_note"
            fi
            [ -n "$_etaTxt" ] && _tail=" — $_etaTxt"
            [ -n "$_tpsN" ] && _tail="$_tail ($_tpsN tok/s)"
            [ -z "$_tail" ] && _tail="…"
            set_status "$_base$_tail" ;;
        done)
            enable_run; enable_swap; disable_ctrl "$STOP_BTN"
            # First time we observe this job's completion, turn the dispatch stamp into an elapsed
            # string; afterwards just reuse it (the done state re-renders on label changes).
            if [ -f "$spool/translate.start" ]; then
                _st="$(/bin/cat "$spool/translate.start" 2>/dev/null)"
                _nw="$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.3f", time' 2>/dev/null)"
                _es="$(/usr/bin/awk -v a="$_nw" -v b="$_st" 'BEGIN{
                    d = a - b; if (a == "" || b == "" || d < 0) d = 0
                    if (d < 60) printf "%.1fs", d; else printf "%dm %02ds", int(d/60), int(d%60) }')"
                /usr/bin/printf '%s' "$_es" > "$spool/translate.elapsed"
                /bin/rm -f "$spool/translate.start"
            else
                _es="$(/bin/cat "$spool/translate.elapsed" 2>/dev/null)"
            fi
            # "Ready (translated in <wall time>, <decode speed>)".
            local _dtail=""
            if [ -n "$_es" ] && [ -n "$_tpsN" ]; then _dtail=" ($VERB_PAST$_from_note in $_es, $_tpsN tok/s)"
            elif [ -n "$_es" ]; then _dtail=" ($VERB_PAST$_from_note in $_es)"
            elif [ -n "$_tpsN" ]; then _dtail=" ($_tpsN tok/s)"
            fi
            set_status "Ready$_dtail" ;;
        cancelled)
            enable_run; enable_swap; disable_ctrl "$STOP_BTN"
            set_status "Cancelled." ;;
        error)
            enable_run; enable_swap; disable_ctrl "$STOP_BTN"
            set_status "Error: ${_msg:-unknown}" ;;
    esac
    # Said last, over the line the state just wrote (the done branch still records its timing).
    [ -n "$_notice" ] && set_status "$_notice"
    return 0
}

reflect_result() {
    [ -f "$spool/result.txt" ] || return 0
    local _rsig="$(/usr/bin/stat -f '%m %z' "$spool/result.txt" 2>/dev/null)"
    [ "$_rsig" = "$LAST_RESULT_SIG" ] && return 0

    if [ "$IS_DOC" = 1 ]; then
        # Document mode: deliver only the finished translation, and only once. result.txt grows
        # per chunk during mapping; hold off until the broker reports "done". status.json is NOT
        # cleared on re-dispatch, so a prior job's stale "done" could otherwise pair with the new
        # job's mid-write result.txt and ship truncated output - gate on the status epoch matching
        # the current job.json epoch so only THIS job's completion delivers. LAST_RESULT_SIG stays
        # unset until we act, so this fires on the completing tick.
        # State and epoch from one copy (see reflect_ui): the previous job's "done" paired with
        # this job's epoch would deliver this job's partial result as finished.
        local _snap="$spool/status.result.json"
        /bin/cp "$spool/status.json" "$_snap" 2>/dev/null || return 0
        local _st="$("$plutil" -extract state raw -o - "$_snap" 2>/dev/null)"
        [ "$_st" = done ] || return 0
        local _ep="$("$plutil" -extract epoch raw -o - "$_snap" 2>/dev/null)"
        local _jep="$("$plutil" -extract epoch raw -o - "$spool/job.json" 2>/dev/null)"
        [ -n "$_ep" ] && [ "$_ep" = "$_jep" ] || return 0
        # The write, the Output field, the forced preview reload and Reveal all live in
        # deliver_doc_result (lib.interp.sh), where a test can reach them without running this
        # loop. Commit LAST_RESULT_SIG only after it ACTED - on a successful write or a surfaced
        # error, never on "no destination recorded", and never before the write. Otherwise a
        # failure is silently masked by reflect_ui's independent "Ready" and the user believes a
        # file was saved that was not. Leaving the signature uncommitted on rc 2 means this retries
        # every tick for as long as the window is open: two reads a second, and the alternative -
        # marking an undelivered result delivered - is worse. Only a fresh dispatch can change it.
        deliver_doc_result "$spool"
        [ $? -eq 2 ] || LAST_RESULT_SIG="$_rsig"
        return 0
    fi

    LAST_RESULT_SIG="$_rsig"
    /bin/cat "$spool/result.txt" \
        | "$dialog" "$window_uuid" "$TGT_EDITOR" omc_set_value_from_stdin plain
}

# Transform mode: once THIS job is done (status epoch matches job.json, the same gate document
# delivery uses), compare the finished result with its source and show what looks wrong. Runs
# once per epoch; interp.transform.run clears the line when it dispatches the next job.
check_result() {
    [ "$IS_TRANSFORM" = 1 ] || return 0
    # State and epoch from one copy (see reflect_ui).
    local _snap="$spool/status.check.json"
    /bin/cp "$spool/status.json" "$_snap" 2>/dev/null || return 0
    local _st="$("$plutil" -extract state raw -o - "$_snap" 2>/dev/null)"
    [ "$_st" = done ] || return 0
    local _ep="$("$plutil" -extract epoch raw -o - "$_snap" 2>/dev/null)"
    local _jep="$("$plutil" -extract epoch raw -o - "$spool/job.json" 2>/dev/null)"
    [ -n "$_ep" ] && [ "$_ep" = "$_jep" ] || return 0
    [ "$_ep" = "$LAST_CHECK_EPOCH" ] && return 0
    [ -f "$spool/result.txt" ] && [ -f "$spool/source.$_ep.txt" ] || return 0
    LAST_CHECK_EPOCH="$_ep"
    transform_check "$spool/source.$_ep.txt" "$spool/result.txt" "$spool/check.txt" \
        "$(/bin/cat "$spool/job.preset" 2>/dev/null)"
    "$dialog" "$window_uuid" "$CHECK_TEXT" "$(/bin/cat "$spool/check.txt" 2>/dev/null)"
}

# The queue counts a window's entry as live only while its poller runs (lib.interp.load.sh).
/usr/bin/printf '%s' "$$" > "$spool/poll.pid"

while [ -d "$spool" ]; do
    sync_group
    sync_models
    sync_variant
    sync_languages
    learn_speed
    advance_job
    ensure_broker
    reflect_ui
    reflect_result
    check_result
    release_finished_job
    /bin/sleep 1
done
