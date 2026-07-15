# interp.poll.sh - backgrounded UI poller, one per window. Spawned by interp.window.init (text
# mode) or interp.doc.init (doc mode). Runs until the spool directory disappears (window close /
# app quit), then exits. Not an OMC command - launched directly via /bin/sh.
#   args: <window_uuid> <spool_dir> [mode]   mode = text (default) | doc
#
# This poller OWNS the mlx-agent map broker. Each tick it:
#   1. syncs the Model picker + a `modelpaths` index to whatever is installed under Models/,
#      auto-selecting a model when none is chosen yet (first-run pickup after a download);
#   2. ensures exactly one broker is running for the selected model, (re)spawning it when the
#      selection changes (in-dialog switch) or the broker died (crash recovery);
#   3. reflects the broker's status.json (-> status line + button state) and result.txt into the
#      window: text mode pushes into the target editor; doc mode writes the finished translation
#      to the chosen output file and points the output QuickLook at it.
# Single ownership here is what lets first-run and model switching work without the init or the
# switch handler managing broker processes. The two windows share this one poller; only the swap
# button (text-only) and the result delivery differ by mode.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"

window_uuid="$1"       # override the (inherited) uuid with the explicit arg
spool="$2"
MODE="${3:-text}"      # text | doc

# The document window has no Swap control; make swap toggles no-ops there so the shared status
# logic below can call them unconditionally.
enable_swap()  { [ "$MODE" = doc ] || enable_ctrl "$SWAP_BTN"; }
disable_swap() { [ "$MODE" = doc ] || disable_ctrl "$SWAP_BTN"; }

# Cross-tick state (globals, UPPERCASE) mutated by the functions below.
LAST_MODELS="__unset__"   # signature of the installed-model set (rebuild the picker on change).
                          # NOT "" - that is the real signature for "zero models", and the
                          # chooser's Done-without-download path must still build the picker.
LAST_UI_SIG=""            # coarse UI signature (state + progress + label) to avoid redundant writes
LAST_RESULT_SIG=""        # mtime+size of result.txt

# --- keep the Model picker in sync with what is installed -------------------
sync_models() {
    local _list="$(list_model_dirs)"
    [ "$_list" = "$LAST_MODELS" ] && return 0
    LAST_MODELS="$_list"

    local _opts="[" _first=1 _oldifs="$IFS" _m _lbl
    : > "$spool/modelpaths.tmp"
    IFS='
'
    for _m in $_list; do
        [ -n "$_m" ] || continue
        _lbl="$(model_display_label "$_m")"
        if [ "$_first" = 1 ]; then _first=0; else _opts="$_opts,"; fi
        _opts="$_opts\"$_lbl\""
        /usr/bin/printf '%s\n' "$_m" >> "$spool/modelpaths.tmp"
    done
    IFS="$_oldifs"
    if [ "$_first" = 1 ]; then _opts="$_opts\"Download models…\""; else _opts="$_opts,\"Download models…\""; fi
    _opts="$_opts]"
    /bin/mv "$spool/modelpaths.tmp" "$spool/modelpaths"

    # Programmatic option/value updates can fire interp.model.changed with a transitional value
    # (an OMC Picker caveat). Mark a short quiet window so that handler ignores those echoes and
    # does not spuriously switch models or open the chooser.
    local _now="$(/bin/date +%s)"
    /usr/bin/printf '%s' "$(( _now + 2 ))" > "$spool/picker_quiet"
    "$dialog" "$window_uuid" "$MODEL_PICKER" omc_set_property "options" "$_opts"

    # Auto-select: if nothing is chosen yet, or the chosen model is gone, pick the first
    # installed one. This is the first-run / post-download pickup path.
    local _sel="$(/bin/cat "$spool/model.dir" 2>/dev/null)"
    local _sel_known=0
    [ -n "$_sel" ] && /usr/bin/grep -Fxq "$_sel" "$spool/modelpaths" 2>/dev/null && _sel_known=1
    if [ "$_sel_known" = 0 ]; then
        _sel="$(/usr/bin/head -1 "$spool/modelpaths" 2>/dev/null)"
        if [ -n "$_sel" ]; then
            /usr/bin/printf '%s' "$_sel" > "$spool/model.dir.tmp" && /bin/mv "$spool/model.dir.tmp" "$spool/model.dir"
        else
            /bin/rm -f "$spool/model.dir"
        fi
    fi

    # Reflect the selected model as the picker's 1-based selection (idempotent for the handler).
    if [ -n "$_sel" ]; then
        local _ci="$(/usr/bin/grep -Fxn "$_sel" "$spool/modelpaths" 2>/dev/null | /usr/bin/head -1 | /usr/bin/cut -d: -f1)"
        case "$_ci" in ''|*[!0-9]*) _ci=1 ;; esac
        "$dialog" "$window_uuid" "$MODEL_PICKER" "$_ci"
    fi
}

# --- ensure one broker is running for the selected model --------------------
ensure_broker() {
    local _sel="$(/bin/cat "$spool/model.dir" 2>/dev/null)"
    if [ -z "$_sel" ] || [ ! -d "$_sel" ]; then
        return 0        # no model yet; the UI phase handling reports it
    fi

    if [ -f "$spool/broker.pid" ]; then
        local _bpid="$(/bin/cat "$spool/broker.pid" 2>/dev/null)"
        local _bmodel="$(/bin/cat "$spool/broker.model" 2>/dev/null)"
        if pid_alive "$_bpid"; then
            [ "$_bmodel" = "$_sel" ] && return 0     # correct broker already running
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
        fi
        /bin/rm -f "$spool/broker.pid" "$spool/broker.model"
        # Clear the previous broker's status/result AND the previous translation's timing so the
        # switched-to model starts clean - otherwise its first idle "ready" would show a stale
        # "(translated in Xs)" from the model we just left.
        /bin/rm -f "$spool/status.json" "$spool/result.txt" "$spool/job.json" \
                   "$spool/translate.start" "$spool/translate.elapsed"
    fi

    disable_ctrl "$TRANSLATE_BTN"; disable_swap; disable_ctrl "$STOP_BTN"
    local _npid="$(spawn_broker "$spool" "$_sel")"
    /usr/bin/printf '%s' "$_npid" > "$spool/broker.pid"
    /usr/bin/printf '%s' "$_sel"  > "$spool/broker.model"
    LAST_UI_SIG=""      # force a fresh status render for the new broker
}

# --- reflect broker status into the window ----------------------------------
reflect_ui() {
    local _sel="$(/bin/cat "$spool/model.dir" 2>/dev/null)"

    local _state="" _chunk="" _total="" _msg="" _tps="" _eta=""
    if [ -f "$spool/status.json" ]; then
        _state=$("$plutil" -extract state raw -o - "$spool/status.json" 2>/dev/null)
        _chunk=$("$plutil" -extract chunk raw -o - "$spool/status.json" 2>/dev/null)
        _total=$("$plutil" -extract total raw -o - "$spool/status.json" 2>/dev/null)
        _msg=$("$plutil" -extract message raw -o - "$spool/status.json" 2>/dev/null)
        _tps=$("$plutil" -extract tok_per_sec raw -o - "$spool/status.json" 2>/dev/null)
        _eta=$("$plutil" -extract eta_sec raw -o - "$spool/status.json" 2>/dev/null)
    fi
    # Synthesize a phase for the pre-status.json window: no model vs. broker warming up.
    if [ -z "$_state" ]; then
        if [ -z "$_sel" ]; then _state="nomodel"; else _state="loading"; fi
    fi

    local _sig="$_state|$_chunk|$_total|$_msg|$_tps|$_eta"
    [ "$_sig" = "$LAST_UI_SIG" ] && return 0
    LAST_UI_SIG="$_sig"

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
            disable_ctrl "$TRANSLATE_BTN"; disable_swap; disable_ctrl "$STOP_BTN"
            set_status "No translation model. Choose \"Download models…\" from the Model menu." ;;
        loading)
            disable_ctrl "$TRANSLATE_BTN"; disable_swap; disable_ctrl "$STOP_BTN"
            set_status "Loading model…" ;;
        ready)
            enable_ctrl "$TRANSLATE_BTN"; enable_swap; disable_ctrl "$STOP_BTN"
            # Fresh post-load state: show the model's measured speed so it can be compared.
            if [ -n "$_tpsN" ]; then set_status "Ready — $_tpsN tok/s"
            else set_status "Ready"; fi ;;
        mapping)
            disable_ctrl "$TRANSLATE_BTN"; disable_swap; enable_ctrl "$STOP_BTN"
            # status.json `chunk` is a COMPLETED count (0..total); the chunk being worked on is
            # completed+1. Show that as a human 1-based "chunk N of M", capped at M, and only when
            # there is more than one chunk (a single chunk needs no counter).
            _cn="$_chunk"; case "$_cn" in ''|*[!0-9]*) _cn=0 ;; esac
            _tn="$_total"; case "$_tn" in ''|*[!0-9]*) _tn=0 ;; esac
            local _base _tail=""
            if [ "$_tn" -ge 2 ]; then
                _cur=$(( _cn + 1 )); [ "$_cur" -gt "$_tn" ] && _cur="$_tn"
                _base="Translating chunk $_cur of $_tn"
            else
                _base="Translating"
            fi
            [ -n "$_etaTxt" ] && _tail=" — $_etaTxt"
            [ -n "$_tpsN" ] && _tail="$_tail ($_tpsN tok/s)"
            [ -z "$_tail" ] && _tail="…"
            set_status "$_base$_tail" ;;
        done)
            enable_ctrl "$TRANSLATE_BTN"; enable_swap; disable_ctrl "$STOP_BTN"
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
            if [ -n "$_es" ] && [ -n "$_tpsN" ]; then _dtail=" (translated in $_es, $_tpsN tok/s)"
            elif [ -n "$_es" ]; then _dtail=" (translated in $_es)"
            elif [ -n "$_tpsN" ]; then _dtail=" ($_tpsN tok/s)"
            fi
            set_status "Ready$_dtail" ;;
        cancelled)
            enable_ctrl "$TRANSLATE_BTN"; enable_swap; disable_ctrl "$STOP_BTN"
            set_status "Cancelled." ;;
        error)
            enable_ctrl "$TRANSLATE_BTN"; enable_swap; disable_ctrl "$STOP_BTN"
            set_status "Error: ${_msg:-unknown}" ;;
    esac
}

reflect_result() {
    [ -f "$spool/result.txt" ] || return 0
    local _rsig="$(/usr/bin/stat -f '%m %z' "$spool/result.txt" 2>/dev/null)"
    [ "$_rsig" = "$LAST_RESULT_SIG" ] && return 0

    if [ "$MODE" = doc ]; then
        # Document mode: deliver only the finished translation, and only once. result.txt grows
        # per chunk during mapping; hold off until the broker reports "done". status.json is NOT
        # cleared on re-dispatch, so a prior job's stale "done" could otherwise pair with the new
        # job's mid-write result.txt and ship truncated output - gate on the status epoch matching
        # the current job.json epoch so only THIS job's completion delivers. LAST_RESULT_SIG stays
        # unset until we act, so this fires on the completing tick.
        local _st="$("$plutil" -extract state raw -o - "$spool/status.json" 2>/dev/null)"
        [ "$_st" = done ] || return 0
        local _ep="$("$plutil" -extract epoch raw -o - "$spool/status.json" 2>/dev/null)"
        local _jep="$("$plutil" -extract epoch raw -o - "$spool/job.json" 2>/dev/null)"
        [ -n "$_ep" ] && [ "$_ep" = "$_jep" ] || return 0
        local _out="$(/bin/cat "$spool/output.path" 2>/dev/null)"
        [ -n "$_out" ] || return 0
        # Write atomically. Commit LAST_RESULT_SIG only after acting (success OR a surfaced error),
        # never before the write - otherwise a write failure is silently masked by reflect_ui's
        # independent "Ready" and the user believes a file was saved that was not.
        /bin/cat "$spool/result.txt" > "$_out.part.$$" 2>/dev/null && /bin/mv "$_out.part.$$" "$_out" 2>/dev/null
        local _write_rc=$?
        if [ "$_write_rc" -eq 0 ]; then
            LAST_RESULT_SIG="$_rsig"
            "$dialog" "$window_uuid" "$QL_OUTPUT" "$_out"
            enable_ctrl "$REVEAL_OUTPUT_BTN"
        else
            /bin/rm -f "$_out.part.$$"
            LAST_RESULT_SIG="$_rsig"
            set_status "Could not write the translation to $_out"
        fi
        return 0
    fi

    LAST_RESULT_SIG="$_rsig"
    /bin/cat "$spool/result.txt" \
        | "$dialog" "$window_uuid" "$TGT_EDITOR" omc_set_value_from_stdin plain
}

while [ -d "$spool" ]; do
    sync_models
    ensure_broker
    reflect_ui
    reflect_result
    /bin/sleep 1
done
