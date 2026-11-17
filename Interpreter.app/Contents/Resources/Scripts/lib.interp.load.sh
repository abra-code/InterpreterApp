# lib.interp.load.sh - the model loading manager. Sourced by lib.interp.sh, so every handler and
# the poller have it. POSIX /bin/sh (macOS bash 3.2). Validate with `sh -n`, never `bash -n`.
#
# Two rules, app-wide (text, document, Text Transform and transform-document windows alike):
#
#   1. ONE JOB AT A TIME. Two local models generating at once are each slower than one alone, and
#      two large models at once can exhaust memory, so a job asked for while another window's job
#      runs waits in a queue. The user is asked first (confirm_job_start), because the wait can be
#      long.
#   2. A MEMORY BUDGET for what is loaded: MEMORY_BUDGET_PERCENT of RAM. A window loads its model
#      only when its job reaches the head of the queue (no load on window open), and before it
#      loads, other windows' models are unloaded, least recently used first, until it fits
#      (make_room_for). They are all idle then, by rule 1. Models of other apps (Cadabra's
#      mlx-agent or llama-server) cannot be unloaded from here; when they leave no room the user
#      is asked before the job is queued (confirm_job_start).
#
# Why the budget is needed at all: an MLX broker copies the weights into its own GPU buffers, so
# two windows on the same 20 GB model hold 40 GB - mmap sharing does not happen on that engine -
# and mlx-agent's own RAM gate compares one model against the whole of RAM, knowing nothing of
# the others.
#
# THE QUEUE is a directory of entry files, Sessions/.queue/<stamp>-<window uuid>, oldest first by
# name (the stamp is fixed-width microseconds). An entry is live while its window's spool exists,
# the spool's queue.entry names it, and the window's poller runs (spool/poll.pid); anything else
# is removed by whoever lists the queue, so a closed window or a crashed poller cannot block it.
# The first live entry is the head: that window may load and run.
#
# A JOB'S LIFE: the Translate/Rewrite handler builds the job into spool/job.next.json (not
# job.json, which the broker reads), then enqueues. The poller, once its entry is the head, makes
# room, spawns the broker, waits for it to load, and only then moves job.next.json to job.json.
# The entry is released when the job reaches a terminal state (done, cancelled, error), when
# Stop withdraws the queued job, or when the broker dies.
#
# An ESTIMATE request (estimate.next, holding a character count; see "speed and time estimates"
# below) travels the same way, for a model never measured on this Mac: it waits its turn, makes
# room, loads the model, and is answered from the measured speed once the model is loaded.
# job.next.model names the model of whichever request is queued.

[ -n "${__INTERP_LOAD_LIB:-}" ] && return 0
__INTERP_LOAD_LIB=1

QUEUE_DIR="$SESSIONS_DIR/.queue"
MEMORY_BUDGET_PERCENT=75

# Test seam for the scan of other apps' engines (see foreign_engines): a file holding the lines
# the scan would print. The real scan lists every mlx-agent and llama-server on the machine, which
# a test can neither stage nor avoid.
FOREIGN_ENGINES_FILE="${INTERP_FOREIGN_ENGINES_FILE:-}"

# --- the job queue --------------------------------------------------------------------------

# Fixed-width microseconds since the epoch, so entry names sort in arrival order.
queue_stamp() {
    /usr/bin/perl -MTime::HiRes=gettimeofday -e '($s, $u) = gettimeofday; printf "%010d%06d", $s, $u'
}

# The spool an entry belongs to (the window uuid follows the stamp's dash).
queue_entry_spool() {   # $1 = entry path
    local _n="$(/usr/bin/basename "$1")"
    /usr/bin/printf '%s' "$SESSIONS_DIR/${_n#*-}"
}

queue_entry_alive() {   # $1 = entry path
    local _spool="$(queue_entry_spool "$1")"
    [ -d "$_spool" ] || return 1
    [ "$(/bin/cat "$_spool/queue.entry" 2>/dev/null)" = "$1" ] || return 1
    pid_alive "$(/bin/cat "$_spool/poll.pid" 2>/dev/null)"
}

# Live entries, oldest first; dead ones are removed on the way.
queue_entries() {
    [ -d "$QUEUE_DIR" ] || return 0
    local _e
    for _e in "$QUEUE_DIR"/*-*; do
        [ -f "$_e" ] || continue
        if queue_entry_alive "$_e"; then
            /usr/bin/printf '%s\n' "$_e"
        else
            /bin/rm -f "$_e"
        fi
    done
}

# The live entries ahead of this window's own, one per line: every other window's live entry when
# this one has none (what the Translate handler asks about before it enqueues).
queue_ahead_of() {   # $1 = spool
    local _mine="$(/bin/cat "$1/queue.entry" 2>/dev/null)"
    local _e
    queue_entries | while IFS= read -r _e; do
        [ "$_e" = "$_mine" ] && break
        /usr/bin/printf '%s\n' "$_e"
    done
}

# The human label an entry was queued with ("Translation with TranslateGemma 27B (6-bit)").
queue_entry_label() {   # $1 = entry path
    /usr/bin/head -1 "$1" 2>/dev/null
}

# True when this window has a live entry and nothing is ahead of it.
queue_is_head() {   # $1 = spool
    local _mine="$(/bin/cat "$1/queue.entry" 2>/dev/null)"
    [ -n "$_mine" ] && [ -f "$_mine" ] || return 1
    [ -z "$(queue_ahead_of "$1")" ]
}

# Join the queue (replacing any entry this window still had). The spool's queue.entry is written
# BEFORE the entry file, so no lister ever sees the file without its owner's claim and removes it.
queue_enqueue() {   # $1 = spool, $2 = label
    /bin/mkdir -p "$QUEUE_DIR" || return 1
    queue_release "$1"
    local _e="$QUEUE_DIR/$(queue_stamp)-$(/usr/bin/basename "$1")"
    /usr/bin/printf '%s' "$_e" > "$1/queue.entry"
    /usr/bin/printf '%s\n' "$2" > "$_e"
}

queue_release() {   # $1 = spool
    local _e="$(/bin/cat "$1/queue.entry" 2>/dev/null)"
    case "$_e" in "$QUEUE_DIR"/*) /bin/rm -f "$_e" ;; esac
    /bin/rm -f "$1/queue.entry"
}

# --- memory ---------------------------------------------------------------------------------

load_ram_bytes() { "$sysctl_tool" -n hw.memsize 2>/dev/null; }

# The budget in MiB, or nothing when RAM cannot be read (then nothing is unloaded or asked).
memory_budget_mib() {
    local _ram="$(load_ram_bytes)"
    case "$_ram" in ''|*[!0-9]*) return 0 ;; esac
    [ "$_ram" -gt 0 ] || return 0
    /usr/bin/printf '%s' "$(( _ram / 1048576 * MEMORY_BUDGET_PERCENT / 100 ))"
}

# Bytes of a model on disk: a folder (MLX, or a GGUF install) or a single .gguf file. -L follows
# symlinks, so a library entry linked to elsewhere is still measured.
model_bytes() {   # $1 = model folder or file
    /usr/bin/du -skL "$1" 2>/dev/null | /usr/bin/awk '{ printf "%.0f", $1 * 1024; exit }'
}

# MiB an engine running a model of this many bytes is estimated to hold: the weights, 15% for the
# context cache and work buffers, and 768 MiB of runtime. Cadabra's estimate (scan_engine_footprints),
# which errs on the safe side.
engine_footprint_mib() {   # $1 = model bytes
    case "$1" in ''|*[!0-9]*) /usr/bin/printf '0'; return 0 ;; esac
    /usr/bin/printf '%s' "$(( $1 / 1048576 * 115 / 100 + 768 ))"
}

model_footprint_mib() {   # $1 = model folder or file
    engine_footprint_mib "$(model_bytes "$1")"
}

# "14.2 GB" for a MiB count.
format_mib() {   # $1 = MiB
    /usr/bin/awk -v m="$1" 'BEGIN { printf "%.1f GB", m / 1024 }'
}

# The model folder a spool's running broker holds, or nothing when it runs none.
spool_broker_model() {   # $1 = spool
    pid_alive "$(/bin/cat "$1/broker.pid" 2>/dev/null)" || return 0
    local _key="$(/bin/cat "$1/broker.model" 2>/dev/null)"
    /usr/bin/printf '%s' "${_key%%|*}"
}

# Other Interpreter windows' running brokers, one line each, least recently active first:
#   <last activity, epoch seconds> <footprint MiB> <spool>
# Activity is the broker's last status write (it writes on every state change and during a job).
own_engines_except() {   # $1 = this window's spool
    local _d _m _t
    for _d in "$SESSIONS_DIR"/*/; do
        _d="${_d%/}"
        [ "$_d" = "$1" ] && continue
        _m="$(spool_broker_model "$_d")"
        [ -n "$_m" ] && [ -e "$_m" ] || continue
        _t="$(/usr/bin/stat -f '%m' "$_d/status.json" 2>/dev/null)"
        [ -n "$_t" ] || _t="$(/usr/bin/stat -f '%m' "$_d/broker.pid" 2>/dev/null)"
        /usr/bin/printf '%s %s %s\n' "${_t:-0}" "$(model_footprint_mib "$_m")" "$_d"
    done | /usr/bin/sort -n
}

# Engines of other apps (and orphans of an earlier Interpreter run), one line each:
#   <pid> <footprint MiB> <model name>
# Every mlx-agent that holds a model (--model) and every llama-server, minus the pids an
# Interpreter window records. An mlx-agent without --model (map --backend openai, an ACP client)
# holds no weights; the llama-server behind it is counted instead. The patterns match the binary
# name on purpose (Cadabra's scan does the same): other bundles' engines hold memory just the same.
foreign_engines() {
    if [ -n "$FOREIGN_ENGINES_FILE" ]; then
        /bin/cat "$FOREIGN_ENGINES_FILE" 2>/dev/null
        return 0
    fi
    local _own=" " _f _p _args _m _b
    for _f in "$SESSIONS_DIR"/*/broker.pid "$SESSIONS_DIR"/*/llama.pid; do
        [ -f "$_f" ] || continue
        _own="$_own$(/bin/cat "$_f" 2>/dev/null) "
    done
    for _p in $(/usr/bin/pgrep -f '[/]mlx-agent' 2>/dev/null); do
        case "$_own" in *" $_p "*) continue ;; esac
        _args="$(/bin/ps -p "$_p" -o args= 2>/dev/null)"
        case "$_args" in *" --model "*) ;; *) continue ;; esac
        _m="${_args##* --model }"
        _m="${_m%% --*}"
        [ -d "$_m" ] || continue
        /usr/bin/printf '%s %s %s\n' "$_p" "$(model_footprint_mib "$_m")" "$(/usr/bin/basename "$_m")"
    done
    for _p in $(/usr/bin/pgrep -f '[/]llama-server' 2>/dev/null); do
        case "$_own" in *" $_p "*) continue ;; esac
        _args="$(/bin/ps -p "$_p" -o args= 2>/dev/null)"
        _m="${_args##* --model }"
        case "$_m" in *.gguf*) _m="${_m%%.gguf*}.gguf" ;; *) continue ;; esac
        [ -f "$_m" ] || continue
        _b="$(/usr/bin/stat -f '%z' -L "$_m" 2>/dev/null)"
        /usr/bin/printf '%s %s %s\n' "$_p" "$(engine_footprint_mib "$_b")" "$(/usr/bin/basename "$_m")"
    done
}

# Sum of the second field of lines on stdin.
sum_mib() { /usr/bin/awk '{ s += $2 } END { printf "%d", s }'; }

# Unload another window's model: its broker and, for a GGUF model, the llama-server behind it.
# The marker goes first, so that window's poller reads the death as an unload, not a crash, and
# says so. Waits for both to exit (the memory is what this is for), escalating to SIGKILL.
evict_engine() {   # $1 = the other window's spool
    local _b="$(/bin/cat "$1/broker.pid" 2>/dev/null)"
    local _l="$(/bin/cat "$1/llama.pid" 2>/dev/null)"
    /usr/bin/printf '%s' "$(/bin/date +%s)" > "$1/evicted"
    /bin/rm -f "$1/job.notice"
    kill_broker_pid "$_b"
    kill_llama_pid "$_l"
    local _w=0
    while { pid_alive "$_b" || pid_alive "$_l"; } && [ "$_w" -lt 30 ]; do
        /bin/sleep 0.2
        _w=$(( _w + 1 ))
    done
    local _a
    if pid_alive "$_b"; then
        _a="$(/bin/ps -p "$_b" -o args= 2>/dev/null)"
        case "$_a" in "$AGENT_BIN"|"$AGENT_BIN "*) /bin/kill -KILL "$_b" 2>/dev/null ;; esac
    fi
    if pid_alive "$_l"; then
        _a="$(/bin/ps -p "$_l" -o args= 2>/dev/null)"
        case "$_a" in "$LLAMA_SERVER_BIN"|"$LLAMA_SERVER_BIN "*) /bin/kill -KILL "$_l" 2>/dev/null ;; esac
    fi
}

# Make room for this window's model before it loads: unload other windows' models, least recently
# used first, until this one fits the budget beside what stays. Called only by the window at the
# head of the queue, so every other Interpreter window is idle. Other apps' engines are counted
# but never touched (the user was asked about them when the job was queued). When nothing can be
# unloaded the load goes ahead anyway: alone, a model too big for the Mac is mlx-agent's RAM gate's
# to refuse, and the load-failure path reports it.
make_room_for() {   # $1 = spool, $2 = model folder
    local _budget="$(memory_budget_mib)"
    [ -n "$_budget" ] || return 0
    local _need="$(model_footprint_mib "$2")"
    local _foreign="$(foreign_engines | sum_mib)"
    local _list="$(own_engines_except "$1")"
    local _own="$(/usr/bin/printf '%s\n' "$_list" | sum_mib)"
    local _line _mib _spool
    local _oldifs="$IFS"
    IFS='
'
    for _line in $_list; do
        [ $(( _need + _foreign + _own )) -gt "$_budget" ] || break
        _mib="$(/usr/bin/printf '%s' "$_line" | /usr/bin/awk '{ print $2 }')"
        _spool="${_line#* * }"
        evict_engine "$_spool"
        _own=$(( _own - _mib ))
    done
    IFS="$_oldifs"
    return 0
}

# --- asking before a job is queued ----------------------------------------------------------

# Run by the Translate/Rewrite handlers just before they publish a job. Asks, in turn:
#   - when another window's job is running or waiting: queue this one behind it, or cancel;
#   - when other apps' models leave no room in the budget for this window's model: load anyway,
#     or cancel.
# Returns 0 to go ahead, 1 when the user canceled (or the question could not be shown).
# JOB_QUEUED_BEHIND is 1 after a go-ahead that queues behind another window's job, for the
# handler's status line.
JOB_QUEUED_BEHIND=0
confirm_job_start() {   # $1 = spool, $2 = model folder, $3 = model label
    local _ahead="$(queue_ahead_of "$1")"
    local _rc
    JOB_QUEUED_BEHIND=0
    if [ -n "$_ahead" ]; then
        JOB_QUEUED_BEHIND=1
        local _n="$(/usr/bin/printf '%s\n' "$_ahead" | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
        local _first="$(queue_entry_label "$(/usr/bin/printf '%s\n' "$_ahead" | /usr/bin/head -1)")"
        local _more=""
        [ "$_n" -gt 1 ] && _more="

$(( _n - 1 )) more waiting after it."
        "$alert" --level caution --title "Another job is running" --ok "Queue" --cancel "Cancel" \
"Another window is busy: ${_first}.${_more}

Interpreter runs one job at a time, so this one would start when the others are done. That can take a while."
        _rc=$?
        [ "$_rc" -eq 0 ] || return 1
    fi
    confirm_memory_for "$1" "$2" "$3"
}

# The memory half of confirm_job_start. Other Interpreter windows' models are not counted: they
# are unloaded to make room when this job's turn comes (make_room_for).
confirm_memory_for() {   # $1 = spool, $2 = model folder, $3 = model label
    [ -n "$2" ] || return 0
    # This window's broker already holds the model: nothing new will load.
    [ "$(spool_broker_model "$1")" = "$2" ] && return 0
    local _foreign_list="$(foreign_engines)"
    [ -n "$_foreign_list" ] || return 0
    local _budget="$(memory_budget_mib)"
    [ -n "$_budget" ] || return 0
    local _foreign="$(/usr/bin/printf '%s\n' "$_foreign_list" | sum_mib)"
    local _need="$(model_footprint_mib "$2")"
    [ $(( _need + _foreign )) -gt "$_budget" ] || return 0
    local _names="$(/usr/bin/printf '%s\n' "$_foreign_list" | /usr/bin/awk '{ $1 = ""; $2 = ""; sub(/^ +/, ""); print }' \
        | /usr/bin/sort -u | /usr/bin/paste -s -d ',' - | /usr/bin/sed 's/,/, /g')"
    local _rc
    "$alert" --level caution --title "High Memory Usage" --ok "Load Anyway" --cancel "Cancel" \
"Loading ${3} ($(format_mib "$_need")) will likely cause high memory pressure.

Models in other apps:  $(format_mib "$_foreign") (${_names})
Combined total:        $(format_mib $(( _need + _foreign )))
Recommended maximum:   $(format_mib "$_budget") (${MEMORY_BUDGET_PERCENT}% of memory)

This may cause slowdowns or instability. Consider closing the other app's model first."
    _rc=$?
    [ "$_rc" -eq 0 ]
}

# --- the poller's side -----------------------------------------------------------------------

# True while this window's published job (job.json) is still running: the broker is alive and its
# status does not yet report the job's epoch as done, cancelled or failed.
job_active() {   # $1 = spool
    [ -f "$1/job.json" ] || return 1
    pid_alive "$(/bin/cat "$1/broker.pid" 2>/dev/null)" || return 1
    local _jep="$("$plutil" -extract epoch raw -o - "$1/job.json" 2>/dev/null)"
    local _sep="$("$plutil" -extract epoch raw -o - "$1/status.json" 2>/dev/null)"
    [ -n "$_jep" ] && [ "$_sep" = "$_jep" ] || return 0
    case "$("$plutil" -extract state raw -o - "$1/status.json" 2>/dev/null)" in
        done|cancelled|error) return 1 ;;
    esac
    return 0
}

# Withdraw a job that has not been handed to the broker yet (Stop, or a model or transform switch
# while it waited). $2 is said in the status line while the window is idle (job.notice).
withdraw_queued_job() {   # $1 = spool, [$2 = notice]
    /bin/rm -f "$1/job.next.json" "$1/estimate.next" "$1/job.next.model" "$1/load.wanted"
    queue_release "$1"
    if [ -n "${2:-}" ]; then
        /usr/bin/printf '%s' "$2" > "$1/job.notice"
        /bin/rm -f "$1/evicted"
    fi
}

# A translation job's queue label.
translation_job_label() {   # $1 = model folder
    /usr/bin/printf 'Translation with %s' "$(model_display_label "$1")"
}

# --- speed and time estimates -----------------------------------------------------------------
#
# The model no longer loads when a window opens, so its speed is no longer shown on its own. What
# each load and each finished job measured is remembered instead, in Speeds.tsv (both libraries,
# translate and transform, share it), and the Estimate Time button (interp.estimate) answers from
# it without loading anything. Only a model never measured on this Mac is loaded for the answer,
# through the same queue and memory budget as a job (estimate.next, see advance_job).
#
# Two kinds of line, tab-separated:
#   model <TAB> <model folder name> <TAB> <tok/s> <TAB> <load seconds>
#   job   <TAB> <job key>           <TAB> <seconds per 1000 characters>
# The job key is "translate|<model folder name>" or "<transform id>|<model folder name>": a
# summary writes far less than it reads, a translation about as much, so the time per character is
# kept per transform as well as per model.
#
# Seconds per character, learned from finished jobs, is the better estimate: it includes reading
# the input, chunking and every per-chunk cost. Before any job, the warm-up tok/s gives a rough one,
# assuming ESTIMATE_TOKENS_PER_CHAR output tokens per input character (about 4 characters per token
# in English; more tokens for scripts such as Chinese, so it is rough).
SPEEDS_FILE="$APP_SUPPORT/Speeds.tsv"
ESTIMATE_TOKENS_PER_CHAR="0.3"
# Jobs shorter than this are mostly fixed cost and would teach a per-character time far too high.
LEARN_MIN_CHARS=200

speed_get() {   # $1 = model | job, $2 = key, $3 = field number (3 or 4)
    [ -f "$SPEEDS_FILE" ] || return 0
    /usr/bin/awk -F'\t' -v t="$1" -v k="$2" -v f="$3" \
        '$1 == t && $2 == k { v = $f } END { if (v != "") print v }' "$SPEEDS_FILE" 2>/dev/null
}

# Replace the line of this type and key (rewritten whole, then renamed into place).
speed_put() {   # $1 = model | job, $2 = key, $3... = values
    /bin/mkdir -p "$APP_SUPPORT" || return 1
    local _t="$1" _k="$2"
    shift 2
    local _tmp="$SPEEDS_FILE.$$"
    {
        [ -f "$SPEEDS_FILE" ] && /usr/bin/awk -F'\t' -v t="$_t" -v k="$_k" '!($1 == t && $2 == k)' "$SPEEDS_FILE"
        /usr/bin/printf '%s\t%s' "$_t" "$_k"
        local _v
        for _v in "$@"; do /usr/bin/printf '\t%s' "$_v"; done
        /usr/bin/printf '\n'
    } > "$_tmp" && /bin/mv "$_tmp" "$SPEEDS_FILE"
}

# The job key of a window's job on a model (see above). A window with a preset.file is a transform
# window.
job_speed_key() {   # $1 = spool, $2 = model folder
    local _preset="$(/bin/cat "$1/preset.file" 2>/dev/null)"
    local _kind="translate"
    if [ -n "$_preset" ]; then
        _kind="$("$plutil" -extract id raw -o - "$_preset" 2>/dev/null)"
        [ -n "$_kind" ] || _kind="transform"
    fi
    /usr/bin/printf '%s|%s' "$_kind" "$(/usr/bin/basename "$2")"
}

# "45s", "2m 10s", "1h 05m".
format_duration() {   # $1 = seconds
    /usr/bin/awk -v s="$1" 'BEGIN {
        s = int(s + 0.5); if (s < 1) s = 1
        if (s < 60) printf "%ds", s
        else if (s < 3600) printf "%dm %02ds", int(s / 60), s % 60
        else printf "%dh %02dm", int(s / 3600), int((s % 3600) / 60) }'
}

# The estimate for a text, as one sentence for the status line; nothing when this model was never
# measured. $4 = 1 when the window's broker already holds the model (no load time to add).
estimate_sentence() {   # $1 = characters, $2 = model folder, $3 = job key, $4 = loaded (0|1)
    local _chars="$1" _model="$(/usr/bin/basename "$2")"
    case "$_chars" in ''|*[!0-9]*) return 0 ;; esac
    local _spk="$(speed_get job "$3" 3)"
    local _tps="$(speed_get model "$_model" 3)"
    local _load="$(speed_get model "$_model" 4)"
    local _text=""
    case "$_spk" in
        ''|*[!0-9.]*) ;;
        *) _text="About $(format_duration "$(/usr/bin/awk -v c="$_chars" -v k="$_spk" 'BEGIN { print c * k / 1000 }')") for $_chars characters." ;;
    esac
    if [ -z "$_text" ]; then
        case "$_tps" in
            ''|*[!0-9.]*|0|0.*) return 0 ;;
        esac
        _text="Roughly $(format_duration "$(/usr/bin/awk -v c="$_chars" -v r="$ESTIMATE_TOKENS_PER_CHAR" -v t="$_tps" 'BEGIN { print c * r / t }')") for $_chars characters, from the model's speed ($(/usr/bin/printf '%.0f' "$_tps") tok/s); it gets more accurate after a run."
    fi
    if [ "$4" != 1 ]; then
        case "$_load" in
            ''|*[!0-9]*) ;;
            *) _text="$_text Loading the model first takes about $(format_duration "$_load")." ;;
        esac
    fi
    /usr/bin/printf '%s' "$_text"
}

# Remember a load: its time, and the warm-up speed when the engine measured one (the llama-server
# path reports none at load; a finished job's speed fills it in).
learn_model_load() {   # $1 = model folder, $2 = load seconds, $3 = tok/s (may be empty)
    local _m="$(/usr/bin/basename "$1")"
    local _tps="$3"
    case "$_tps" in ''|*[!0-9.]*|0|0.*) _tps="$(speed_get model "$_m" 3)" ;; esac
    speed_put model "$_m" "$_tps" "$2"
}

# Remember a finished job: the model's speed during it, and its seconds per 1000 characters,
# averaged with what was known (half and half, so one odd run moves it but does not own it).
learn_job() {   # $1 = model folder, $2 = job key, $3 = seconds, $4 = characters, $5 = tok/s (may be empty)
    local _m="$(/usr/bin/basename "$1")"
    case "$5" in
        ''|*[!0-9.]*|0|0.*) ;;
        *) speed_put model "$_m" "$5" "$(speed_get model "$_m" 4)" ;;
    esac
    case "$4" in ''|*[!0-9]*) return 0 ;; esac
    [ "$4" -ge "$LEARN_MIN_CHARS" ] || return 0
    local _old="$(speed_get job "$2" 3)"
    local _new="$(/usr/bin/awk -v s="$3" -v c="$4" -v o="$_old" 'BEGIN {
        k = s * 1000 / c; if (o != "" && o + 0 > 0) k = (k + o) / 2; printf "%.3f", k }')"
    speed_put job "$2" "$_new"
}
