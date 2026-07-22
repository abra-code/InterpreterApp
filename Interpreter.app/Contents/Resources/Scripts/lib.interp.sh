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
PDFTEXT_BIN="$OMC_APP_BUNDLE_PATH/Contents/Support/pdftext"
# llama.cpp engine for GGUF models (provisioned by update_interpreter.sh --with-llama; dylibs
# sit beside the binary). Absent in an MLX-only build - gguf models then fail to spawn cleanly.
LLAMA_SERVER_BIN="$OMC_APP_BUNDLE_PATH/Contents/Support/Llama.cpp/llama-server"

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

# True when a directory holds an installed model of EITHER engine: an MLX safetensors dir
# (config.json) or a GGUF install (a single <file>.gguf inside). The by-shape test is the same
# idea AIChat's model_engine uses; every "is this installed" check routes through here so the
# two engines stay indistinguishable to the rest of the app.
model_installed_at() {   # $1 = model dir
    [ -f "$1/config.json" ] && return 0
    set -- "$1"/*.gguf
    [ -f "$1" ]
}

# Engine of an installed model dir, by shape: mlx (config.json) or gguf (a .gguf file).
# Defaults to mlx so existing callers keep their exact behavior for anything unrecognized.
model_engine_of() {   # $1 = model dir
    if [ -f "$1/config.json" ]; then echo mlx; return 0; fi
    set -- "$1"/*.gguf
    if [ -f "$1" ]; then echo gguf; else echo mlx; fi
}

# The (first) .gguf file inside a gguf model dir; empty when none.
gguf_file_in() {   # $1 = model dir
    set -- "$1"/*.gguf
    [ -f "$1" ] && /usr/bin/printf '%s' "$1"
}

# Resolve the model directory: the first translategemma-* dir under Models holding a model,
# else any dir holding one (either engine). Symlinks are resolved (the weight loader needs a
# real path). Prints the resolved path and returns 0, or returns 1 when no model is present.
resolve_model_dir() {
    local _d
    for _d in "$MODELS_DIR"/*translategemma*/ "$MODELS_DIR"/*/; do
        [ -d "$_d" ] || continue
        model_installed_at "${_d%/}" || continue
        ( cd "$_d" && pwd -P )
        return 0
    done
    return 1
}

model_label_for() { /usr/bin/basename "$1"; }

# The model FAMILY of an installed dir / repo name, matched case-insensitively on the name:
# translategemma | milmmt | generic. The family decides how a translation job is composed
# (chat messages vs raw completion prompt) and how the broker is spawned.
model_family_of() {   # $1 = model dir path or repo name
    local _b=$(/usr/bin/basename "$1" | /usr/bin/tr '[:upper:]' '[:lower:]')
    case "$_b" in
        *translategemma*) echo translategemma ;;
        *milmmt*)         echo milmmt ;;
        *hy-mt*|*hymt*)   echo hymt ;;
        *)                echo generic ;;
    esac
}

# Every installed model directory (either engine - see model_installed_at), one resolved
# absolute path per line, in stable lexical order. translategemma-* first, then any other model
# dir (same order as resolve_model_dir), de-duplicated so a translategemma dir is not also
# listed by the catch-all.
list_model_dirs() {
    local _seen="" _d _r
    for _d in "$MODELS_DIR"/*translategemma*/ "$MODELS_DIR"/*/; do
        [ -d "$_d" ] || continue
        model_installed_at "${_d%/}" || continue
        _r=$( cd "$_d" && pwd -P )
        case "$_seen" in *"[$_r]"*) continue ;; esac
        _seen="$_seen[$_r]"
        /usr/bin/printf '%s\n' "$_r"
    done
}

# A short human label naming the model, e.g. "TranslateGemma 27B (4-bit)" or
# "MiLMMT-46 12B (4-bit)". Falls back to the bare directory name for anything that is not a
# recognised quant of a known family. Name parsing is case-insensitive (TranslateGemma repos
# use -12b-, MiLMMT repos -12B-).
model_display_label() {   # $1 = model dir path
    local _b="$(/usr/bin/basename "$1")" _p="" _q="" _f=""
    local _l=$(/usr/bin/printf '%s' "$_b" | /usr/bin/tr '[:upper:]' '[:lower:]')
    case "$_l" in *-27b-*) _p="27B" ;; *-12b-*) _p="12B" ;; *-4b-*) _p="4B" ;; *-7b-*) _p="7B" ;; *-1.8b-*) _p="1.8B" ;; esac
    case "$_l" in *8bit) _q="8-bit" ;; *6bit) _q="6-bit" ;; *5bit) _q="5-bit" ;; *4bit) _q="4-bit" ;; esac
    case "$(model_family_of "$_b")" in
        translategemma) _f="TranslateGemma" ;;
        milmmt)         _f="MiLMMT-46" ;;
        hymt)           _f="Hy-MT2" ;;
    esac
    if [ -n "$_f" ] && [ -n "$_p" ] && [ -n "$_q" ]; then /usr/bin/printf '%s %s (%s)' "$_f" "$_p" "$_q"; else /usr/bin/printf '%s' "$_b"; fi
}

# Spawn the long-lived map broker for a model into a spool, backgrounded with /dev/null stdin
# (it does NOT treat that as parent-death; it exits when the spool dir disappears or is reaped).
# Prints the broker's pid.
#
# ENGINE DISPATCH (by model-dir shape, see model_engine_of):
#   mlx  - mlx-agent map loads the safetensors dir in-process. TranslateGemma conversions need
#          "<end_of_turn>" unioned into the stop set (their generation_config omits it); MiLMMT
#          declares its stop tokens itself.
#   gguf - the applet launches the bundled llama-server on a free localhost port with the dir's
#          .gguf (spawn_llama_server below), then mlx-agent map --backend openai serves the SAME
#          spool from it. The broker owns the load wait: llama-server answers /health 503 while
#          loading and map's openai engine polls patiently, keeping status.json in "loading" -
#          so this function returns immediately either way and the poller's UI flow is identical
#          for both engines. The server's lifetime is tied to the broker's by a watchdog.
spawn_broker() {   # $1 = spool dir, $2 = model dir
    local _gguf _port _bpid _lpid
    if [ "$(model_engine_of "$2")" = gguf ]; then
        _gguf=$(gguf_file_in "$2")
        if [ -z "$_gguf" ] || [ ! -x "$LLAMA_SERVER_BIN" ]; then
            # No .gguf (half-installed) or no bundled llama.cpp: spawn nothing. The poller keeps
            # showing "loading" and retries next tick; the condition is diagnosable from this
            # marker (overwritten, not appended - the retry ticks must not grow a log).
            /usr/bin/printf 'gguf spawn failed: gguf=%s llama-server=%s\n' \
                "${_gguf:-none}" "$LLAMA_SERVER_BIN" > "$1/gguf.spawn.error"
            echo ""
            return 0
        fi
        _port=$(spawn_llama_server "$1" "$_gguf") || { echo ""; return 0; }
        "$AGENT_BIN" map --backend openai --base-url "http://127.0.0.1:$_port/v1" --spool "$1" \
            --temperature "$GEN_TEMP" --max-new-tokens "$GEN_MAXTOK" \
            < /dev/null >> "$1/agent.log" 2>&1 &
        _bpid=$!
        # Watchdog: when the broker dies - model switch, app quit, spool reaped - take the
        # server with it, whatever the death path was. Checks every 2s; the tiny subshell holds
        # no window state. The server pid VALUE is captured NOW: the common broker-death cause
        # is the spool being deleted on window close, so reading llama.pid after the death
        # would find nothing and leak the server. The pid is re-verified by argv before the
        # kill (kill_llama_pid) so a recycled pid is never signalled.
        _lpid=$(/bin/cat "$1/llama.pid" 2>/dev/null)
        (
            while /bin/kill -0 "$_bpid" 2>/dev/null; do /bin/sleep 2; done
            kill_llama_pid "$_lpid"
        ) < /dev/null > /dev/null 2>&1 &
        echo "$_bpid"
        return 0
    fi
    if [ "$(model_family_of "$2")" = translategemma ]; then
        "$AGENT_BIN" map --model "$2" --spool "$1" \
            --extra-eos-token "$EXTRA_EOS" --temperature "$GEN_TEMP" --max-new-tokens "$GEN_MAXTOK" \
            < /dev/null >> "$1/agent.log" 2>&1 &
    else
        "$AGENT_BIN" map --model "$2" --spool "$1" \
            --temperature "$GEN_TEMP" --max-new-tokens "$GEN_MAXTOK" \
            < /dev/null >> "$1/agent.log" 2>&1 &
    fi
    echo $!
}

# Launch the bundled llama-server for a .gguf on a free localhost port. Prints the port (and
# records llama.pid/llama.port in the spool); returns 1 without printing when no port bound.
# Any stale server recorded in this spool is retired FIRST and waited on, so a model switch
# never holds two ggufs in memory (mirrors ensure_broker's wait for the old MLX broker).
#
# Flags mirror AIChat V2's launch line: --jinja renders the gguf's own chat template
# server-side (the map broker never templates client-side); q8_0 KV cache halves context
# memory at negligible quality cost; --sleep-idle-seconds matches the MLX engine's idle-unload
# policy. Memory fitting is left to llama-server's own --fit default - Interpreter runs one
# model per window, not a fleet, so AIChat's sibling-aware budget is not needed.
spawn_llama_server() {   # $1 = spool dir, $2 = gguf file ; prints the port
    local _spool="$1" _gguf="$2" _old _port _p _w _spid
    _old=$(/bin/cat "$_spool/llama.pid" 2>/dev/null)
    if [ -n "$_old" ]; then
        kill_llama_pid "$_old"
        _w=0
        while pid_alive "$_old" && [ "$_w" -lt 25 ]; do /bin/sleep 0.2; _w=$(( _w + 1 )); done
    fi
    /bin/rm -f "$_spool/llama.pid" "$_spool/llama.port"
    _port=""
    for _p in 8321 8322 8323 8324 8325 8326 8327 8328; do
        if ! /usr/bin/nc -z 127.0.0.1 "$_p" 2>/dev/null; then _port="$_p"; break; fi
    done
    [ -n "$_port" ] || return 1
    "$LLAMA_SERVER_BIN" --host 127.0.0.1 --port "$_port" --model "$_gguf" --jinja \
        --cache-type-k q8_0 --cache-type-v q8_0 --sleep-idle-seconds 600 \
        < /dev/null >> "$_spool/llama.log" 2>&1 &
    _spid=$!
    /usr/bin/printf '%s' "$_spid"  > "$_spool/llama.pid"
    /usr/bin/printf '%s' "$_port" > "$_spool/llama.port"
    echo "$_port"
}

# TERM a pid only after confirming argv[0] is our bundled llama-server (recycled-pid safety,
# the llama twin of kill_broker_pid).
kill_llama_pid() {   # $1 = pid
    case "$1" in ''|*[!0-9]*) return 0 ;; esac
    local _a="$(/bin/ps -p "$1" -o args= 2>/dev/null)"
    case "$_a" in
        "$LLAMA_SERVER_BIN"|"$LLAMA_SERVER_BIN "*) /bin/kill -TERM "$1" 2>/dev/null ;;
    esac
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

# Prompt name of a language code for a model FAMILY, from the family's language file
# (Resources/languages.<family>.tsv: code <TAB> prompt name; # comments allowed). That file is
# also the authority on which languages the family supports: no row (or no file) = no name.
# The prompt name can differ from the display name - e.g. MiLMMT-46 was trained on plain
# "Portuguese" and "Norwegian", not "Portuguese (Brazil)" or "Norwegian Bokmal". Quotes and
# backslashes are stripped so the name can be embedded in a JSON string (the shipped names
# contain neither; this is a guard, not a feature).
family_prompt_lang_name() {   # $1 = family, $2 = code
    [ -n "$1" ] && [ -n "$2" ] || return 0
    /usr/bin/awk -F'\t' -v c="$2" '/^[[:space:]]*#/ { next } $1==c { print $2; exit }' \
        "$RESOURCES_DIR/languages.$1.tsv" 2>/dev/null | /usr/bin/tr -d '"\\'
}

# Resolve a picker's 1-based index to a language code via the spool's langcodes file. Prints the
# code (empty for a missing/non-numeric index or an out-of-range row).
resolve_lang_code() {   # $1 = spool, $2 = 1-based index
    case "$2" in ''|*[!0-9]*) return 0 ;; esac
    /usr/bin/sed -n "${2}p" "$1/langcodes"
}

# Populate the From/To language pickers for the CURRENT model family and restore the saved
# selection. The list is sorted alphabetically by display name (the shipped TSV stays the source
# of truth): we sort a copy into a temp file first (not a "sort | while" pipe) so the loop runs in
# this shell and $_opts survives it; sorting by the leading name field is safe because names
# contain no tabs. When the selected model's family ships a language file
# (languages.<family>.tsv), the options are FILTERED to the codes it lists, so the pickers only
# ever offer what the model supports; a family without one (TranslateGemma, generic) gets the
# full list. The family populated for is recorded in the spool (langfamily) so the poller can
# re-populate when a model switch changes it.
#
# A parallel ordered langcodes file lets handlers map a picker index -> language code. Selections
# persist as language CODES (FromLang/ToLang defaults keys) - an index would silently point at a
# different language whenever the family list changes. Legacy FromIndex/ToIndex values (1-based
# rows of the full sorted list, reproduced in langcodes.all) are migrated here, one-shot, by
# writing the resolved code. A saved code absent from the current family's list falls back to
# en/es by code (then row 1) WITHOUT persisting the fallback: the programmatic picker sets below
# are wrapped in a lang_quiet window that the change handlers honor, so switching to a family
# that lacks the saved language masks the preference for the session instead of erasing it -
# switching back restores it.
populate_language_pickers() {   # $1 = spool
    local _spool="$1"
    local _tab=$(/usr/bin/printf '\t')
    local _sorted="$_spool/languages.sorted.tsv"
    local _family=$(model_family_of "$(/bin/cat "$_spool/model.dir" 2>/dev/null)")
    local _famfile="$RESOURCES_DIR/languages.$_family.tsv"
    local _opts="["
    local _first=1
    local _name _code _legacy
    LC_ALL=C /usr/bin/sort -f "$RESOURCES_DIR/languages.tsv" > "$_sorted"
    /bin/rm -f "$_spool/langcodes" "$_spool/langcodes.all"
    while IFS="$_tab" read -r _name _code; do
        [ -n "$_name" ] || continue
        [ -n "$_code" ] || continue
        /usr/bin/printf '%s\n' "$_code" >> "$_spool/langcodes.all"
        if [ -f "$_famfile" ]; then
            [ -n "$(family_prompt_lang_name "$_family" "$_code")" ] || continue
        fi
        if [ "$_first" = 1 ]; then _first=0; else _opts="$_opts,"; fi
        _opts="$_opts\"$_name\""
        /usr/bin/printf '%s\n' "$_code" >> "$_spool/langcodes"
    done < "$_sorted"
    _opts="$_opts]"
    /usr/bin/printf '%s' "$_family" > "$_spool/langfamily"

    "$dialog" "$window_uuid" "$FROM_PICKER" omc_set_property "options" "$_opts"
    "$dialog" "$window_uuid" "$TO_PICKER" omc_set_property "options" "$_opts"

    local _from_code=$(/usr/bin/defaults read "$BUNDLE_ID" FromLang 2>/dev/null)
    local _to_code=$(/usr/bin/defaults read "$BUNDLE_ID" ToLang 2>/dev/null)
    if [ -z "$_from_code" ]; then
        _legacy=$(/usr/bin/defaults read "$BUNDLE_ID" FromIndex 2>/dev/null)
        case "$_legacy" in ''|*[!0-9]*) ;; *) _from_code=$(/usr/bin/sed -n "${_legacy}p" "$_spool/langcodes.all") ;; esac
        [ -n "$_from_code" ] && /usr/bin/defaults write "$BUNDLE_ID" FromLang "$_from_code"
    fi
    if [ -z "$_to_code" ]; then
        _legacy=$(/usr/bin/defaults read "$BUNDLE_ID" ToIndex 2>/dev/null)
        case "$_legacy" in ''|*[!0-9]*) ;; *) _to_code=$(/usr/bin/sed -n "${_legacy}p" "$_spool/langcodes.all") ;; esac
        [ -n "$_to_code" ] && /usr/bin/defaults write "$BUNDLE_ID" ToLang "$_to_code"
    fi

    local _from=$(lang_code_index "$_spool" "$_from_code")
    [ -n "$_from" ] || _from=$(lang_code_index "$_spool" en)
    case "$_from" in ''|*[!0-9]*) _from=1 ;; esac
    local _to=$(lang_code_index "$_spool" "$_to_code")
    [ -n "$_to" ] || _to=$(lang_code_index "$_spool" es)
    case "$_to" in ''|*[!0-9]*) _to=$_from ;; esac

    # Quiet window for the programmatic sets below: the change handlers skip persisting inside
    # it, so a family-filter fallback (saved language not in this list) cannot overwrite the
    # saved preference. Mirrors the model picker's picker_quiet.
    /usr/bin/printf '%s' "$(( $(/bin/date +%s) + 2 ))" > "$_spool/lang_quiet"
    "$dialog" "$window_uuid" "$FROM_PICKER" "$_from"
    "$dialog" "$window_uuid" "$TO_PICKER" "$_to"
}

# Compose a translation job from source text (read on STDIN) and drop it into the spool for the
# map broker; the poller reflects progress/results. This is the shared core of dispatch used by
# both windows. The source text goes to a per-epoch file (printf %s never interprets content) so
# a rapid re-dispatch can never pair one job's text with another job's language metadata; job.json
# then carries only fixed, safe values. Callers hold the dispatch lock and own the UI transitions.
#
# The job's template is FAMILY-SPECIFIC (family of the spool's selected model.dir, written by
# the poller that owns the broker):
#   - translategemma (and generic): TranslateGemma's structured chat messages, rendered against
#     the model's own chat template ({type, source_lang_code, target_lang_code, text}). The
#     generic fallback also covers a missing model.dir (empty basename) - safe because Translate
#     is only reachable once the poller has a ready broker, which requires model.dir to exist;
#     a NEW raw-prompt family must be added to model_family_of and branched here explicitly, or
#     it would silently get this chat-messages job.
#   - milmmt: MiLMMT-46 ships NO chat template and is prompted as a raw completion per its model
#     card - "Translate this from <From> to <To>:\n<From>: ...\n<To>:" with add_special_tokens
#     false and ENGLISH LANGUAGE NAMES, not codes. The \n in the heredoc below are literal
#     two-character sequences, which is exactly what the JSON string needs.
#   - hymt: Hy-MT2 IS a chat-template family, but takes a plain instruction string (the official
#     model-card English template, target language by ENGLISH NAME), not TranslateGemma's
#     structured content. The template names only the target; the source name is still resolved
#     as the support check.
# Returns non-zero (publishing nothing) only when a named-language path (milmmt, hymt) cannot
# resolve its language names - the caller surfaces that as a UI error.
publish_translation_job() {   # $1 = spool, $2 = from code, $3 = to code ; source text on STDIN
    local _spool="$1" _from="$2" _to="$3"
    local _family=$(model_family_of "$(/bin/cat "$_spool/model.dir" 2>/dev/null)")
    local _from_name="" _to_name=""
    case "$_family" in milmmt|hymt)
        # Names come from the family's language file (its prompt names differ from the display
        # names - Portuguese/Norwegian for MiLMMT, plain "Chinese" for Hy-MT2), which doubles as
        # the support check: an unsupported code resolves to nothing and the job is refused
        # rather than mistranslated.
        _from_name=$(family_prompt_lang_name "$_family" "$_from")
        _to_name=$(family_prompt_lang_name "$_family" "$_to")
        if [ -z "$_from_name" ] || [ -z "$_to_name" ]; then
            # Swallow stdin so the caller's pipe never blocks or SIGPIPEs, then report failure.
            /bin/cat > /dev/null
            return 1
        fi ;;
    esac

    local _epoch=$(pb_get "interp_epoch_${window_uuid}")
    case "$_epoch" in ''|*[!0-9]*) _epoch=0 ;; esac
    _epoch=$((_epoch + 1))
    pb_set "interp_epoch_${window_uuid}" "$_epoch"

    local _srcfile="source.${_epoch}.txt"
    /bin/cat > "$_spool/$_srcfile"

    if [ "$_family" = milmmt ]; then
        /bin/cat > "$_spool/job.json.tmp" <<EOF
{"epoch":$_epoch,"output":"stitch","budget_tokens":$BUDGET_TOKENS,"text_file":"$_srcfile","add_special_tokens":false,"prompt":"Translate this from $_from_name to $_to_name:\n$_from_name: {{chunk}}\n$_to_name:"}
EOF
    elif [ "$_family" = hymt ]; then
        /bin/cat > "$_spool/job.json.tmp" <<EOF
{"epoch":$_epoch,"output":"stitch","budget_tokens":$BUDGET_TOKENS,"text_file":"$_srcfile","messages":[{"role":"user","content":"Translate the following text into $_to_name. Note that you should only output the translated result without any additional explanation:\n\n{{chunk}}"}]}
EOF
    else
        /bin/cat > "$_spool/job.json.tmp" <<EOF
{"epoch":$_epoch,"output":"stitch","budget_tokens":$BUDGET_TOKENS,"text_file":"$_srcfile","messages":[{"role":"user","content":[{"type":"text","source_lang_code":"$_from","target_lang_code":"$_to","text":"{{chunk}}"}]}]}
EOF
    fi
    # Drop the previous job's output so the poller re-pushes only once the broker writes fresh
    # output; stamp the dispatch moment (high-resolution) and clear any prior elapsed so the poller
    # can report how long this translation took when it observes "done".
    /bin/rm -f "$_spool/result.txt" "$_spool/translate.elapsed"
    /usr/bin/perl -MTime::HiRes=time -e 'printf "%.3f", time' > "$_spool/translate.start" 2>/dev/null
    /bin/mv "$_spool/job.json.tmp" "$_spool/job.json"
}

# True if the file carries the PDF signature "%PDF-" near its start. Detection is by content, not
# extension, so a PDF dropped or sent to the service without a .pdf suffix is still routed here. PDF
# readers - including the PDFKit helper this routes to - tolerate a few leading bytes before the
# header (a prepended BOM, stray whitespace, mail/gateway mangling), so we scan the first 1 KB rather
# than requiring the signature at offset 0: missing it would send a real PDF to textutil, which
# silently misreads the bytes as text and produces garbage. Scanning the same window PDFKit does
# keeps the two in agreement. A non-PDF that merely contains "%PDF-" early routes to the helper and
# fails cleanly ("can't read") instead of translating garbage, so the false-positive direction is safe.
is_pdf() {   # $1 = path
    /usr/bin/head -c 1024 "$1" 2>/dev/null | LC_ALL=C /usr/bin/grep -qa '%PDF-'
}

# Reject glyph-mapping garbage from a PDF whose fonts lack a usable ToUnicode map: such a PDF
# extracts as a single placeholder glyph repeated (PDFKit emits U+00FF, or the replacement char), so
# one character dominates the output, whereas real text - in any script - never concentrates on a
# single character. The analysis lives in pdf_text_usable.pl (a separate file, not composed inline
# here); it returns 0 for usable text and non-zero for garbage. Runs once per dispatch.
pdf_text_is_usable() {   # $1 = extracted text file
    /usr/bin/perl "$SCRIPTS_DIR/pdf_text_usable.pl" "$1" 2>/dev/null
}

# Convert a document to plain UTF-8 text, writing it to $2. Returns 0 on a real conversion, non-zero
# when the document could not be read.
#
# PDF is handled by the bundled PDFKit helper (pdftext), NOT textutil: textutil cannot parse PDF and
# silently misreads the raw bytes as plain text, emitting binary garbage. A helper failure (cannot
# open / locked / no text layer, i.e. a scanned image-only PDF) or output that does not survive the
# garbage gate above is treated as a convert failure. Its output is already UTF-8.
#
# Everything else goes through textutil. Plain-text inputs are deliberately NOT short-circuited
# (copied) - they go through textutil too, because the translation pipeline needs UTF-8 and textutil
# normalizes to it: a UTF-16/BOM'd .txt (common from Windows) is correctly transcoded, whereas a raw
# copy would hand the model UTF-16 bytes. -encoding UTF-8 pins the OUTPUT encoding so the result is
# UTF-8 regardless of the OS/locale default. (textutil still can't reliably detect a BOM-less
# non-UTF-8 single-byte input and may mis-transcode it - but a copy would not fix that either.)
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

    if is_pdf "$1"; then
        "$PDFTEXT_BIN" "$1" > "$2" 2>/dev/null || { /bin/rm -f "$2"; return 1; }
        pdf_text_is_usable "$2" || { /bin/rm -f "$2"; return 1; }
        return 0
    fi

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
