# lib.interp.transform.sh - text transformer support: presets, transformer model library, job
# building and broker spawning. Sourced AFTER lib.interp.sh by the transform window handlers, the
# poller in transform mode, and the model chooser in transform kind.
# POSIX /bin/sh (macOS bash 3.2). Validate with `sh -n`, never `bash -n`.
#
# A PRESET is what the user picks ("Humanize"): one JSON file in Resources/Transformers/, named
# <NN>-<id>.json so the file name orders the picker. It names a model FAMILY and carries everything
# the run needs, so a new transformer is a data file, not code:
#   id, name, family, languages, notice, output_suffix, button
#   server   - llama-server flags: ctx_size, top_k, min_p, chat_template_kwargs (a JSON string)
#   sampling - mlx-agent map flags: temperature, top_p, max_new_tokens
#   job      - the job.json prototype exactly as the map broker reads it (prompt or messages with
#              {{chunk}}, add_special_tokens, budget_tokens, output)
# Jobs are built by copying `job` out with plutil and setting epoch/text_file with plutil, so preset
# text (newlines, quotes, non-ASCII) is never spliced into JSON by hand.
#
# Installed transformer models live in Transformers/ under app support, apart from the translation
# Models/, so neither picker can offer the other kind. A model dir's family is looked up by its
# directory name in models.transform.catalog.tsv (column 3 is the install name); a dir the catalog
# does not list is not offered to any preset.

[ -n "${__INTERP_TRANSFORM_LIB:-}" ] && return 0
__INTERP_TRANSFORM_LIB=1

TRANSFORMS_DIR="$APP_SUPPORT/Transformers"
PRESETS_DIR="${INTERP_PRESETS_DIR:-$RESOURCES_DIR/Transformers}"
TRANSFORM_CATALOG_TSV="${INTERP_TRANSFORM_CATALOG_TSV:-$RESOURCES_DIR/models.transform.catalog.tsv}"

# Transform window control ids (must match transform.window.json). Editors, model picker, Stop,
# status and character count share the translator's ids so the mode-aware poller and the shared
# handlers work unchanged; the run button keeps TRANSLATE_BTN's id (40) for the same reason.
PRESET_PICKER=22
NOTICE_TEXT=310
CHECK_TEXT=320

# Preset files in picker order, one path per line.
list_preset_files() {
    local _f
    for _f in "$PRESETS_DIR"/*.json; do
        [ -f "$_f" ] && /usr/bin/printf '%s\n' "$_f"
    done
}

# One preset value by key path ("sampling.temperature"), raw; empty when absent.
preset_get() {   # $1 = preset file, $2 = key path
    "$plutil" -extract "$2" raw -o - "$1" 2>/dev/null
}

# The preset file with this id, or nothing.
preset_file_for_id() {   # $1 = id
    local _f
    for _f in "$PRESETS_DIR"/*.json; do
        [ -f "$_f" ] || continue
        [ "$(preset_get "$_f" id)" = "$1" ] && { /usr/bin/printf '%s' "$_f"; return 0; }
    done
    return 1
}

# Family of an installed transformer dir: the catalog row whose install name (column 3) equals the
# dir's basename. Empty for a dir the catalog does not know.
transform_family_of() {   # $1 = model dir or install name
    local _name="$(/usr/bin/basename "$1")"
    /usr/bin/awk -F'\t' -v n="$_name" '/^[[:space:]]*#/ { next } $3==n { print $1; exit }' \
        "$TRANSFORM_CATALOG_TSV" 2>/dev/null
}

# Installed transformer dirs of one family, in catalog order (best first), resolved absolute paths.
list_transform_dirs() {   # $1 = family
    local _name _dir
    /usr/bin/awk -F'\t' -v f="$1" '/^[[:space:]]*#/ { next } $1==f { print $3 }' \
        "$TRANSFORM_CATALOG_TSV" 2>/dev/null \
    | while IFS= read -r _name; do
        [ -n "$_name" ] || continue
        _dir="$TRANSFORMS_DIR/$_name"
        [ -d "$_dir" ] || continue
        model_installed_at "$_dir" || continue
        ( CDPATH= cd -P -- "$_dir" && pwd -P )
    done
}

# Human name of a transformer family and a short label for an installed variant.
transform_family_display_name() {   # $1 = family
    case "$1" in
        humanizer)  echo "Humanizer" ;;
        gohumanize) echo "GoHumanize" ;;
        *)          echo "$1" ;;
    esac
}

transform_display_label() {   # $1 = model dir
    local _name="$(/usr/bin/basename "$1")"
    local _row="$(/usr/bin/awk -F'\t' -v n="$_name" '/^[[:space:]]*#/ { next } $3==n { print $1 "\t" $4 "\t" $5; exit }' \
        "$TRANSFORM_CATALOG_TSV" 2>/dev/null)"
    if [ -z "$_row" ]; then /usr/bin/printf '%s' "$_name"; return 0; fi
    local _fam="$(/usr/bin/printf '%s' "$_row" | /usr/bin/cut -f1)"
    local _par="$(/usr/bin/printf '%s' "$_row" | /usr/bin/cut -f2)"
    local _bits="$(/usr/bin/printf '%s' "$_row" | /usr/bin/cut -f3)"
    /usr/bin/printf '%s %sB (%s-bit)' "$(transform_family_display_name "$_fam")" "$_par" "$_bits"
}

# Compose a transform job from source text on STDIN and publish it to the spool, the transform twin
# of publish_translation_job (same epoch counter, per-epoch source file, timing stamp, atomic
# publish). Returns non-zero, publishing nothing, when the preset's job cannot be built.
publish_transform_job() {   # $1 = spool, $2 = preset file ; source text on STDIN
    local _spool="$1" _preset="$2"
    local _epoch="$(pb_get "interp_epoch_${window_uuid}")"
    case "$_epoch" in ''|*[!0-9]*) _epoch=0 ;; esac
    _epoch=$((_epoch + 1))
    pb_set "interp_epoch_${window_uuid}" "$_epoch"

    local _srcfile="source.${_epoch}.txt"
    /bin/cat > "$_spool/$_srcfile"

    local _tmp="$_spool/job.json.tmp"
    "$plutil" -extract job json -o "$_tmp" "$_preset" 2>/dev/null \
        && "$plutil" -replace epoch -integer "$_epoch" "$_tmp" 2>/dev/null \
        && "$plutil" -replace text_file -string "$_srcfile" "$_tmp" 2>/dev/null
    if [ $? -ne 0 ]; then
        /bin/rm -f "$_tmp"
        return 1
    fi
    /bin/rm -f "$_spool/result.txt" "$_spool/translate.start" "$_spool/translate.elapsed" "$_spool/check.txt"
    /usr/bin/perl -MTime::HiRes=time -e 'printf "%.3f", time' > "$_spool/translate.start" 2>/dev/null
    /bin/mv "$_tmp" "$_spool/job.json"
}

# Spawn the map broker for a transformer: the bundled llama-server with the preset's server flags,
# then mlx-agent map --backend openai with the preset's sampling. Mirrors spawn_broker's gguf branch
# (same failure marker, same server-follows-broker watchdog). Prints the broker pid, or nothing
# when the server could not be started (the poller retries next tick).
#
# Sampling is per broker PROCESS in mlx-agent map, not per job, which is why the poller keys the
# broker on model AND preset: switching presets restarts it.
spawn_transform_broker() {   # $1 = spool, $2 = model dir, $3 = preset file
    local _spool="$1" _dir="$2" _preset="$3"
    local _gguf="$(gguf_file_in "$_dir")"
    if [ -z "$_gguf" ] || [ ! -x "$LLAMA_SERVER_BIN" ]; then
        /usr/bin/printf 'gguf spawn failed: gguf=%s llama-server=%s\n' \
            "${_gguf:-none}" "$LLAMA_SERVER_BIN" > "$_spool/gguf.spawn.error"
        echo ""
        return 0
    fi

    # Server flags from the preset; each value is checked to be a plain number before use, so a
    # malformed preset cannot inject extra arguments. chat_template_kwargs is passed as ONE argument.
    set --
    local _v="$(preset_get "$_preset" server.ctx_size)"
    case "$_v" in ''|*[!0-9]*) ;; *) set -- "$@" --ctx-size "$_v" ;; esac
    _v="$(preset_get "$_preset" server.top_k)"
    case "$_v" in ''|*[!0-9]*) ;; *) set -- "$@" --top-k "$_v" ;; esac
    _v="$(preset_get "$_preset" server.min_p)"
    case "$_v" in ''|*[!0-9.]*) ;; *) set -- "$@" --min-p "$_v" ;; esac
    # A JSON object written as a string. Written as a JSON object instead, plutil's raw output would
    # be its key names, and llama-server would refuse to start - so anything else is left out.
    _v="$(preset_get "$_preset" server.chat_template_kwargs)"
    case "$_v" in '{'*'}') set -- "$@" --chat-template-kwargs "$_v" ;; esac

    local _port
    _port="$(spawn_llama_server "$_spool" "$_gguf" "$@")"
    if [ -z "$_port" ]; then echo ""; return 0; fi

    local _temp="$(preset_get "$_preset" sampling.temperature)"
    case "$_temp" in ''|*[!0-9.]*) _temp="$GEN_TEMP" ;; esac
    local _topp="$(preset_get "$_preset" sampling.top_p)"
    case "$_topp" in ''|*[!0-9.]*) _topp=1 ;; esac
    local _maxtok="$(preset_get "$_preset" sampling.max_new_tokens)"
    case "$_maxtok" in ''|*[!0-9]*) _maxtok="$GEN_MAXTOK" ;; esac

    "$AGENT_BIN" map --backend openai --base-url "http://127.0.0.1:$_port/v1" --spool "$_spool" \
        --temperature "$_temp" --top-p "$_topp" --max-new-tokens "$_maxtok" \
        < /dev/null >> "$_spool/agent.log" 2>&1 &
    local _bpid=$!
    tie_llama_to_broker "$_spool" "$_bpid"
    echo "$_bpid"
}

# Fact check of a finished rewrite: numbers in the source that are missing from the result, and a
# script switch (Latin in, Chinese out or the reverse). Writes a one-line human summary to
# $3 (empty file when nothing was found). The analysis lives in transform_check.pl.
transform_check() {   # $1 = source file, $2 = result file, $3 = output file
    /usr/bin/perl "$SCRIPTS_DIR/transform_check.pl" "$1" "$2" > "$3" 2>/dev/null || : > "$3"
}

# Fill the Transform picker from the bundled presets and select the saved one (defaults key
# TransformPreset, by preset id), falling back to the first. A parallel `presetfiles` index in the
# spool maps the picker's 1-based index back to a file. Applies the selected preset (see
# apply_preset). The programmatic sets run inside a quiet window that
# interp.transform.preset.changed honors, the same guard the model picker uses.
populate_preset_picker() {   # $1 = spool
    local _spool="$1" _f _name
    local _opts="[" _first=1
    : > "$_spool/presetfiles.tmp"
    for _f in "$PRESETS_DIR"/*.json; do
        [ -f "$_f" ] || continue
        _name="$(preset_get "$_f" name | /usr/bin/tr -d '"\\')"
        [ -n "$_name" ] || continue
        if [ "$_first" = 1 ]; then _first=0; else _opts="$_opts,"; fi
        _opts="$_opts\"$_name\""
        /usr/bin/printf '%s\n' "$_f" >> "$_spool/presetfiles.tmp"
    done
    _opts="$_opts]"
    /bin/mv "$_spool/presetfiles.tmp" "$_spool/presetfiles"

    local _saved="$("$defaults_tool" read "$BUNDLE_ID" TransformPreset 2>/dev/null)"
    local _sel=""
    [ -n "$_saved" ] && _sel="$(preset_file_for_id "$_saved")"
    /usr/bin/grep -Fxq "$_sel" "$_spool/presetfiles" 2>/dev/null || _sel="$(/usr/bin/head -1 "$_spool/presetfiles")"
    local _idx="$(/usr/bin/grep -Fxn "$_sel" "$_spool/presetfiles" 2>/dev/null | /usr/bin/head -1 | /usr/bin/cut -d: -f1)"
    case "$_idx" in ''|*[!0-9]*) _idx=1 ;; esac

    /usr/bin/printf '%s' "$(( $(/bin/date +%s) + 2 ))" > "$_spool/preset_quiet"
    "$dialog" "$window_uuid" "$PRESET_PICKER" omc_set_property "options" "$_opts"
    "$dialog" "$window_uuid" "$PRESET_PICKER" "$_idx"
    [ -n "$_sel" ] && apply_preset "$_spool" "$_sel"
}

# Make a preset the window's current one: record it for the poller (which rebuilds the model list
# for the preset's family and restarts the broker with its sampling) and show its notice and
# button title. Clears the previous run's check line, which described the previous preset's output.
# The run button goes off at once: until the poller's next tick respawns the broker with this
# preset, a job published now would reach the OLD broker, which the respawn then kills with the job
# in it. The poller turns the button back on when the new broker reports ready.
apply_preset() {   # $1 = spool, $2 = preset file
    disable_ctrl "$TRANSLATE_BTN"
    /usr/bin/printf '%s' "$2" > "$1/preset.file.tmp" && /bin/mv "$1/preset.file.tmp" "$1/preset.file"
    : > "$1/ui.stale"      # after the switch is recorded: the poller re-renders the button
    "$dialog" "$window_uuid" "$NOTICE_TEXT" "$(preset_get "$2" notice)"
    local _button="$(preset_get "$2" button)"
    "$dialog" "$window_uuid" "$TRANSLATE_BTN" omc_set_property "title" "${_button:-Run}"
    "$dialog" "$window_uuid" "$CHECK_TEXT" ""
}
