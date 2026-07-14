# lib.interp.sh - shared library for the Interpreter applet. Sourced by every handler.
# POSIX /bin/sh (macOS bash 3.2). Validate with `sh -n`, never `bash -n`.

[ -n "${__INTERP_LIB:-}" ] && return 0
__INTERP_LIB=1

APPLET_NAME="Interpreter"
BUNDLE_ID="com.abracode.Interpreter"

# OMC runtime tools (resolved from the support dir OMC exports).
dialog="$OMC_OMC_SUPPORT_PATH/omc_dialog_control"
next_command="$OMC_OMC_SUPPORT_PATH/omc_next_command"
alert="$OMC_OMC_SUPPORT_PATH/alert"
pasteboard="$OMC_OMC_SUPPORT_PATH/pasteboard"
plutil="/usr/bin/plutil"

# Window + bundle paths.
window_uuid="${OMC_ACTIONUI_WINDOW_UUID:-}"
RESOURCES_DIR="$OMC_APP_BUNDLE_PATH/Contents/Resources"
SCRIPTS_DIR="$RESOURCES_DIR/Scripts"
AGENT_BIN="$OMC_APP_BUNDLE_PATH/Contents/Support/MLX/mlx-agent"

# App support layout.
APP_SUPPORT="$HOME/Library/Application Support/Interpreter"
MODELS_DIR="$APP_SUPPORT/Models"
SESSIONS_DIR="$APP_SUPPORT/Sessions"
CACHE_DIR="$APP_SUPPORT/Cache"
DOWNLOADS_DIR="$APP_SUPPORT/Downloads"

# ActionUI control ids (must match interpreter.window.json).
MODEL_PICKER=25
FROM_PICKER=20
TO_PICKER=21
SWAP_BTN=30
TRANSLATE_BTN=40
STOP_BTN=41
SRC_EDITOR=100
TGT_EDITOR=200
CHAR_TEXT=110
STATUS_TEXT=300

# mlx-agent map generation settings for translation.
EXTRA_EOS="<end_of_turn>"
GEN_TEMP="0"
GEN_MAXTOK="2048"
BUDGET_TOKENS="1200"

# --- helpers ---------------------------------------------------------------

pb_set() { "$pasteboard" "$1" set "$2"; }
pb_get() { "$pasteboard" "$1" get 2>/dev/null; }

spool_dir_for() { echo "$SESSIONS_DIR/$1"; }

set_status()   { "$dialog" "$window_uuid" "$STATUS_TEXT" "$1"; }
enable_ctrl()  { "$dialog" "$window_uuid" "$1" omc_enable; }
disable_ctrl() { "$dialog" "$window_uuid" "$1" omc_disable; }

# Resolve the model directory: the first translategemma-* dir under Models with a config.json,
# else any model dir with a config.json. Symlinks are resolved (the weight loader needs a real
# path). Prints the resolved path and returns 0, or returns 1 when no model is present.
resolve_model_dir() {
    local _d
    for _d in "$MODELS_DIR"/*translategemma*/ "$MODELS_DIR"/*/; do
        [ -d "$_d" ] || continue
        [ -f "${_d}config.json" ] || continue
        ( cd "$_d" && pwd -P )
        return 0
    done
    return 1
}

model_label_for() { /usr/bin/basename "$1"; }

# Every installed model directory (has a config.json), one resolved absolute path per line, in
# stable lexical order. translategemma-* first, then any other model dir (same order as
# resolve_model_dir), de-duplicated so a translategemma dir is not also listed by the catch-all.
list_model_dirs() {
    local _seen="" _d _r
    for _d in "$MODELS_DIR"/*translategemma*/ "$MODELS_DIR"/*/; do
        [ -d "$_d" ] || continue
        [ -f "${_d}config.json" ] || continue
        _r=$( cd "$_d" && pwd -P )
        case "$_seen" in *"[$_r]"*) continue ;; esac
        _seen="$_seen[$_r]"
        /usr/bin/printf '%s\n' "$_r"
    done
}

# A short human label naming the model, e.g. "TranslateGemma 27B (4-bit)". Falls back to the
# bare directory name for anything that is not a recognised translategemma quant.
model_display_label() {   # $1 = model dir path
    local _b="$(/usr/bin/basename "$1")" _p="" _q=""
    case "$_b" in *-27b-*) _p="27B" ;; *-12b-*) _p="12B" ;; *-4b-*) _p="4B" ;; esac
    case "$_b" in *8bit) _q="8-bit" ;; *4bit) _q="4-bit" ;; esac
    if [ -n "$_p" ] && [ -n "$_q" ]; then /usr/bin/printf 'TranslateGemma %s (%s)' "$_p" "$_q"; else /usr/bin/printf '%s' "$_b"; fi
}

# Spawn the long-lived map broker for a model into a spool, backgrounded with /dev/null stdin
# (it does NOT treat that as parent-death; it exits when the spool dir disappears or is reaped).
# Prints the broker's pid.
spawn_broker() {   # $1 = spool dir, $2 = model dir
    "$AGENT_BIN" map --model "$2" --spool "$1" \
        --extra-eos-token "$EXTRA_EOS" --temperature "$GEN_TEMP" --max-new-tokens "$GEN_MAXTOK" \
        < /dev/null >> "$1/agent.log" 2>&1 &
    echo $!
}

# TERM a pid only after confirming argv[0] is our bundled mlx-agent, so a recycled pid is safe.
kill_broker_pid() {   # $1 = pid
    case "$1" in ''|*[!0-9]*) return 0 ;; esac
    local _a="$(/bin/ps -p "$1" -o args= 2>/dev/null)"
    case "$_a" in
        "$AGENT_BIN"|"$AGENT_BIN "*) /bin/kill -TERM "$1" 2>/dev/null ;;
    esac
}

pid_alive() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; /bin/kill -0 "$1" 2>/dev/null; }

# Free space (bytes) on the volume that would hold a path. The path's nearest existing ancestor
# is probed, so a not-yet-created target still reports its destination volume.
disk_free_bytes() {   # $1 = path
    local _p="$1"
    while [ -n "$_p" ] && [ ! -e "$_p" ]; do _p=$(/usr/bin/dirname "$_p"); [ "$_p" = "/" ] && break; done
    /bin/df -k "$_p" 2>/dev/null | /usr/bin/awk 'NR==2 { print $4 * 1024; exit }'
}
