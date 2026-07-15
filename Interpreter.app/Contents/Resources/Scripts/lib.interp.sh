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

# Document-translation window control ids (must match doc.window.json). The pickers, Translate,
# Stop and status ids are deliberately shared with the text window so the mode-aware poller and
# the interp.from/to.changed + interp.stop handlers work in both windows without change.
QL_INPUT=120
QL_OUTPUT=220
INPUT_PATH_TEXT=130
OUTPUT_PATH_TEXT=230
CHOOSE_OUTPUT_BTN=231
REVEAL_OUTPUT_BTN=232

# mlx-agent map generation settings for translation.
EXTRA_EOS="<end_of_turn>"
GEN_TEMP="0"
GEN_MAXTOK="2048"
BUDGET_TOKENS="1200"

# --- helpers ---------------------------------------------------------------

pb_set() { "$pasteboard" "$1" set "$2"; }
pb_get() { "$pasteboard" "$1" get 2>/dev/null; }

# Open the document-translation window for a file: stash the path on the private handoff key that
# interp.doc.init consumes, then chain to the doc window. Shared by the launch/drop dispatcher,
# File > Open, and the "Translate with Interpreter" file service so the handoff stays in one place.
route_document() { pb_set "INTERP_DOC_INPUT_PATH" "$1"; "$next_command" "$OMC_CURRENT_COMMAND_GUID" "interp.doc"; }

spool_dir_for() { echo "$SESSIONS_DIR/$1"; }

set_status()   { "$dialog" "$window_uuid" "$STATUS_TEXT" "$1"; }
enable_ctrl()  { "$dialog" "$window_uuid" "$1" omc_enable; }
disable_ctrl() { "$dialog" "$window_uuid" "$1" omc_disable; }

# Present a modal alert over this window (ActionUI/OMC omc_present_alert): title, message, one OK
# button. Use this for errors the user must see now, rather than only leaving a status-line trace.
present_alert() { "$dialog" "$window_uuid" omc_window omc_present_alert "$1" "$2" "OK::"; }

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

# --- shared translation helpers (used by both the text and document windows) -------------------

# 1-based row of a language code in the spool's langcodes file, or empty if absent.
lang_code_index() {   # $1 = spool, $2 = code
    /usr/bin/grep -n "^${2}\$" "$1/langcodes" 2>/dev/null | /usr/bin/head -1 | /usr/bin/cut -d: -f1
}

# Resolve a picker's 1-based index to a language code via the spool's langcodes file. Prints the
# code (empty for a missing/non-numeric index or an out-of-range row).
resolve_lang_code() {   # $1 = spool, $2 = 1-based index
    case "$2" in ''|*[!0-9]*) return 0 ;; esac
    /usr/bin/sed -n "${2}p" "$1/langcodes"
}

# Populate the From/To language pickers from languages.tsv and restore the saved selection.
# The list is sorted alphabetically by display name (the shipped TSV stays the source of truth):
# we sort a copy into a temp file first (not a "sort | while" pipe) so the loop runs in this shell
# and $_opts survives it; sorting by the leading name field is safe because names contain no tabs.
# A parallel ordered langcodes file lets handlers map a picker index -> language code. Default
# From/To are looked up by code (en/es) rather than assumed positions, since the list is sorted.
populate_language_pickers() {   # $1 = spool
    local _spool="$1"
    local _tab=$(/usr/bin/printf '\t')
    local _sorted="$_spool/languages.sorted.tsv"
    local _opts="["
    local _first=1
    local _name _code
    LC_ALL=C /usr/bin/sort -f "$RESOURCES_DIR/languages.tsv" > "$_sorted"
    /bin/rm -f "$_spool/langcodes"
    while IFS="$_tab" read -r _name _code; do
        [ -n "$_name" ] || continue
        [ -n "$_code" ] || continue
        if [ "$_first" = 1 ]; then _first=0; else _opts="$_opts,"; fi
        _opts="$_opts\"$_name\""
        /usr/bin/printf '%s\n' "$_code" >> "$_spool/langcodes"
    done < "$_sorted"
    _opts="$_opts]"

    "$dialog" "$window_uuid" "$FROM_PICKER" omc_set_property "options" "$_opts"
    "$dialog" "$window_uuid" "$TO_PICKER" omc_set_property "options" "$_opts"

    local _nlangs=$(/usr/bin/wc -l < "$_spool/langcodes" | /usr/bin/tr -d ' ')
    [ -n "$_nlangs" ] && [ "$_nlangs" -ge 1 ] 2>/dev/null || _nlangs=1
    local _default_from=$(lang_code_index "$_spool" en); case "$_default_from" in ''|*[!0-9]*) _default_from=1 ;; esac
    local _default_to=$(lang_code_index "$_spool" es);   case "$_default_to"   in ''|*[!0-9]*) _default_to=$_default_from ;; esac
    local _saved_from=$(/usr/bin/defaults read "$BUNDLE_ID" FromIndex 2>/dev/null)
    local _saved_to=$(/usr/bin/defaults read "$BUNDLE_ID" ToIndex 2>/dev/null)
    case "$_saved_from" in ''|*[!0-9]*) _saved_from=$_default_from ;; esac
    case "$_saved_to" in ''|*[!0-9]*) _saved_to=$_default_to ;; esac
    [ "$_saved_from" -ge 1 ] && [ "$_saved_from" -le "$_nlangs" ] 2>/dev/null || _saved_from=$_default_from
    [ "$_saved_to" -ge 1 ] && [ "$_saved_to" -le "$_nlangs" ] 2>/dev/null || _saved_to=$_default_to
    "$dialog" "$window_uuid" "$FROM_PICKER" "$_saved_from"
    "$dialog" "$window_uuid" "$TO_PICKER" "$_saved_to"
}

# Compose a translation job from source text (read on STDIN) and drop it into the spool for the
# map broker; the poller reflects progress/results. This is the shared core of dispatch used by
# both windows. The source text goes to a per-epoch file (printf %s never interprets content) so
# a rapid re-dispatch can never pair one job's text with another job's language metadata; job.json
# then carries only fixed, safe values. Callers hold the dispatch lock and own the UI transitions.
publish_translation_job() {   # $1 = spool, $2 = from code, $3 = to code ; source text on STDIN
    local _spool="$1" _from="$2" _to="$3"
    local _epoch=$(pb_get "interp_epoch_${window_uuid}")
    case "$_epoch" in ''|*[!0-9]*) _epoch=0 ;; esac
    _epoch=$((_epoch + 1))
    pb_set "interp_epoch_${window_uuid}" "$_epoch"

    local _srcfile="source.${_epoch}.txt"
    /bin/cat > "$_spool/$_srcfile"

    /bin/cat > "$_spool/job.json.tmp" <<EOF
{"epoch":$_epoch,"output":"stitch","budget_tokens":$BUDGET_TOKENS,"text_file":"$_srcfile","messages":[{"role":"user","content":[{"type":"text","source_lang_code":"$_from","target_lang_code":"$_to","text":"{{chunk}}"}]}]}
EOF
    # Drop the previous job's output so the poller re-pushes only once the broker writes fresh
    # output; stamp the dispatch moment (high-resolution) and clear any prior elapsed so the poller
    # can report how long this translation took when it observes "done".
    /bin/rm -f "$_spool/result.txt" "$_spool/translate.elapsed"
    /usr/bin/perl -MTime::HiRes=time -e 'printf "%.3f", time' > "$_spool/translate.start" 2>/dev/null
    /bin/mv "$_spool/job.json.tmp" "$_spool/job.json"
}

# Convert a document to plain UTF-8 text via textutil, writing it to $2. Returns 0 on a real
# conversion, non-zero when the document could not be read.
#
# Plain-text inputs are deliberately NOT short-circuited (copied) - they go through textutil too,
# because the translation pipeline needs UTF-8 and textutil normalizes to it: a UTF-16/BOM'd .txt
# (common from Windows) is correctly transcoded, whereas a raw copy would hand the model UTF-16
# bytes. -encoding UTF-8 pins the OUTPUT encoding so the result is UTF-8 regardless of the OS/locale
# default. (textutil still can't reliably detect a BOM-less non-UTF-8 single-byte input and may
# mis-transcode it - but a copy would not fix that either, only break it differently.)
#
# textutil's OWN exit status is unusable: it returns 0 even for a file it cannot read - e.g. a
# .pages package yields "The file isn't in the correct format." on stderr and writes NO output while
# still exiting 0 - so we judge success by the real signals instead: a conversion FAILED if textutil
# emitted any diagnostic on stderr, or produced no output file. A stale $2 from a prior attempt is
# removed first so a missing file is detectable. A readable-but-empty document still succeeds here
# (an empty output file); the caller's whitespace check reports that separately as "nothing to
# translate".
convert_to_plain_text() {   # $1 = input path, $2 = output file
    /bin/rm -f "$2"
    local _err=$(/usr/bin/textutil -convert txt -encoding UTF-8 -output "$2" "$1" 2>&1 >/dev/null)
    [ -z "$_err" ] && [ -f "$2" ]
}

# Default translated-output path for an input document: "<name-no-ext>-translated.txt" next to the
# original, made unique by appending -1, -2, ... so an existing file is never overwritten.
unique_output_path() {   # $1 = input path
    local _dir _base _cand _n
    _dir=$(/usr/bin/dirname "$1")
    _base=$(/usr/bin/basename "$1"); _base="${_base%.*}"
    _cand="$_dir/${_base}-translated.txt"
    _n=1
    while [ -e "$_cand" ]; do
        _cand="$_dir/${_base}-translated-${_n}.txt"
        _n=$((_n + 1))
    done
    /usr/bin/printf '%s' "$_cand"
}
