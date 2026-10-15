# lib.interp.transform.sh - text transformer support: presets, transformer model library, job
# building and broker spawning. Sourced AFTER lib.interp.sh by the transform window handlers, the
# poller in transform mode, and the model chooser in transform kind.
# POSIX /bin/sh (macOS bash 3.2). Validate with `sh -n`, never `bash -n`.
#
# A PRESET is what the user picks ("Humanize"): one JSON file in Resources/Transformers/, named
# <NN>-<id>.json so the file name orders the picker. It names a model FAMILY and carries everything
# the run needs, so a new transformer is a data file, not code:
#   id, name, family, languages, notice, output_suffix, button, checks, status_working, status_done
#   server   - llama-server flags: ctx_size, top_k, min_p, chat_template_kwargs (a JSON string)
#   sampling - mlx-agent map flags: temperature, top_p, max_new_tokens
#   job      - the job.json prototype exactly as the map broker reads it (prompt or messages with
#              {{chunk}}, add_special_tokens, budget_tokens, output)
# Jobs are built by copying `job` out with plutil and setting epoch/text_file with plutil, so preset
# text (newlines, quotes, non-ASCII) is never spliced into JSON by hand.
#
# One transform can run on more than one model family: each family gets its own file (its prompt
# and sampling are tuned to that model), and the files share the transform's id and name. These
# are the transform's VARIANTS. The Transform picker shows a transform once, at its first file's
# place; the Model picker lists the installed models of every variant's family; and the window's
# preset (spool/preset.file) is always the variant made for the selected model's family, so the
# job, the server flags, the notice and the checks all follow the Model picker.
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

# Every variant of the preset's transform (the preset files with its id), in picker order, one path
# per line. A preset without an id, or whose id no file in the presets folder has, is its own only
# variant.
preset_variants() {   # $1 = preset file
    local _id="$(preset_get "$1" id)"
    local _f _found=""
    if [ -n "$_id" ]; then
        for _f in "$PRESETS_DIR"/*.json; do
            [ -f "$_f" ] || continue
            [ "$(preset_get "$_f" id)" = "$_id" ] || continue
            /usr/bin/printf '%s\n' "$_f"
            _found=1
        done
    fi
    [ -n "$_found" ] || /usr/bin/printf '%s\n' "$1"
}

# The model families a transform runs on, one per line, in variant order, each once.
preset_families() {   # $1 = preset file
    local _v
    preset_variants "$1" | while IFS= read -r _v; do
        preset_get "$_v" family
        echo
    done | /usr/bin/awk 'NF && !seen[$0]++'
}

# The variant of the preset's transform made for a model family, or nothing.
preset_variant_for_family() {   # $1 = preset file, $2 = family
    [ -n "$2" ] || return 0
    local _v
    preset_variants "$1" | while IFS= read -r _v; do
        if [ "$(preset_get "$_v" family)" = "$2" ]; then
            /usr/bin/printf '%s' "$_v"
            break
        fi
    done
}

# Installed models a transform can run on: those of every variant's family, variant by variant.
list_preset_model_dirs() {   # $1 = preset file
    local _fam
    for _fam in $(preset_families "$1"); do
        list_transform_dirs "$_fam"
    done
}

# The defaults key that remembers the model last picked for a transform, so a transform with two
# families goes back to the one its user chose ("TransformModelName.humanize"). Empty for a preset
# without a usable id.
transform_model_pref_key() {   # $1 = preset file
    local _id="$(preset_get "$1" id | /usr/bin/tr -cd 'A-Za-z0-9_-')"
    [ -n "$_id" ] && /usr/bin/printf 'TransformModelName.%s' "$_id"
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
        gemma4it)   echo "Gemma 4" ;;
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
    # The preset this job was built from, for the post-run check (the picker may have moved on by
    # the time the job finishes).
    /usr/bin/printf '%s' "$_preset" > "$_spool/job.preset"
    /bin/mv "$_tmp" "$_spool/job.json"
}

# --- the language of a text, for transforms -----------------------------------------------------
#
# A transform keeps the language of its input, so only the LANGUAGE matters here, not the variant
# the translator distinguishes: langid without --keep-script ("zh", "pt"). The floor is higher than
# Detect language's 0.5, because here an answer is used to refuse a run or to flag a finished one,
# and a false alarm on a sound result is worse than a missed one. Ordinary sentences score
# 0.8-1.0; a lone word or a block of code usually does not, and is then simply not judged.
TRANSFORM_LANG_MIN_CONFIDENCE="0.8"

# The language of a text file as a bare language code ("pl"), or nothing when langid will not say.
transform_text_language() {   # $1 = text file
    [ -x "$LANGID_BIN" ] || return 0
    local _raw
    _raw=$("$LANGID_BIN" --min-confidence "$TRANSFORM_LANG_MIN_CONFIDENCE" --file "$1" 2>/dev/null)
    /usr/bin/printf '%s' "$_raw" | /usr/bin/head -1 | /usr/bin/tr -cd 'a-z'
}

# English name of a bare language code, without the variant: "zh" -> "Chinese", "pt" ->
# "Portuguese". From languages.tsv (the first row for the language, its parenthesis dropped), so a
# language the app does not list falls back to its code.
transform_language_name() {   # $1 = bare code
    local _name=$(/usr/bin/awk -F'\t' -v c="$1" '$2 == c || index($2, c "-") == 1 { print $1; exit }' \
        "$RESOURCES_DIR/languages.tsv" 2>/dev/null)
    _name="${_name%% (*}"
    /usr/bin/printf '%s' "${_name:-$1}"
}

# Refuse a text that is clearly in a language the preset's model was not made for. A preset may
# list its languages ("languages": ["en", "zh"] - the Humanizer was trained on English and Chinese
# only); one without the field takes any language. A text langid cannot place is let through: the
# refusal is for a confident mismatch, never for doubt.
# Prints the reason and returns 1 when refused; prints nothing and returns 0 otherwise.
#
# When another variant of the transform takes the language (Humanize also runs on Gemma 4), the
# reason names the models instead of the transform and says which one to choose.
transform_language_refusal() {   # $1 = preset file, $2 = text file
    local _langs=$(preset_bare_languages "$1")
    [ -n "$_langs" ] || return 0
    local _lang=$(transform_text_language "$2")
    [ -n "$_lang" ] || return 0
    case ",$_langs," in *",$_lang,"*) return 0 ;; esac

    # "English", "English and Chinese", "English, Chinese and Japanese".
    local _list="" _code _n=0
    local _count=$(/usr/bin/printf '%s' "$_langs" | /usr/bin/tr ',' '\n' | /usr/bin/grep -c .)
    case "$_count" in ''|*[!0-9]*) _count=0 ;; esac
    for _code in $(/usr/bin/printf '%s' "$_langs" | /usr/bin/tr ',' ' '); do
        _n=$((_n + 1))
        if [ "$_n" -eq 1 ]; then _list="$(transform_language_name "$_code")"
        elif [ "$_n" -eq "$_count" ]; then _list="$_list and $(transform_language_name "$_code")"
        else _list="$_list, $(transform_language_name "$_code")"
        fi
    done

    local _alt=$(preset_family_for_language "$1" "$_lang")
    if [ -n "$_alt" ]; then
        /usr/bin/printf '%s' "$(transform_family_display_name "$(preset_get "$1" family)") works on $_list text, and this looks like $(transform_language_name "$_lang"). Choose a $(transform_family_display_name "$_alt") model under Model to rewrite it."
    else
        /usr/bin/printf '%s' "$(preset_get "$1" name) works on $_list text, and this looks like $(transform_language_name "$_lang")."
    fi
    return 1
}

# The family of another variant of the preset's transform that takes a language, or nothing.
preset_family_for_language() {   # $1 = preset file, $2 = bare language code
    local _v _vl
    preset_variants "$1" | while IFS= read -r _v; do
        [ "$_v" = "$1" ] && continue
        _vl=$(preset_bare_languages "$_v")
        case ",$_vl," in
            ,,|*",$2,"*) preset_get "$_v" family; break ;;
        esac
    done
}

# The languages a preset lists, as bare codes ("en,zh"): a listed "zh-Hant" counts as "zh", the
# level langid answers at here. Empty for a preset that takes any language.
preset_bare_languages() {   # $1 = preset file
    "$plutil" -extract languages json -o - "$1" 2>/dev/null | /usr/bin/tr -cd 'A-Za-z,-' \
        | /usr/bin/tr 'A-Z' 'a-z' | /usr/bin/sed -e 's/-[a-z]*//g'
}

# The words the status line uses for a preset's run: "Summarizing..." while it runs and "Ready
# (summarized in 14s)" after. Optional fields status_working and status_done; a preset without them
# rewrites.
transform_status_working() {   # $1 = preset file
    local _w="$(preset_get "$1" status_working)"
    /usr/bin/printf '%s' "${_w:-Rewriting}"
}
transform_status_done() {   # $1 = preset file
    local _w="$(preset_get "$1" status_done)"
    /usr/bin/printf '%s' "${_w:-rewritten}"
}

# The suffix a preset's document output is named with ("report.pdf" -> "report-humanized.txt").
# It takes the place the target language code has in the translator's names, so the same output
# helpers (unique_output_path, doc_output_path_for, set_doc_output) name, memoize and uniquify it.
# Only letters, digits, "-" and "_" are kept - it becomes part of a file name - and a preset
# without one gets "rewritten".
transform_output_suffix() {   # $1 = preset file
    local _s="$(preset_get "$1" output_suffix | /usr/bin/tr -cd 'A-Za-z0-9_-')"
    /usr/bin/printf '%s' "${_s:-rewritten}"
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

# Fact check of a finished rewrite: numbers missing from or added to the result, a script switch
# (Latin in, Chinese out or the reverse), and a result far shorter than its source. Writes a
# one-line human summary to $3 (empty file when nothing was found). The analysis lives in
# transform_check.pl. A preset's optional "checks" string ("numbers script length language")
# picks which of them apply - "Make concise" is supposed to shorten, and "Summarize" checks only
# for added numbers ("added-numbers") because it is supposed to leave most of them out - and
# without one all of them run.
#
# The language check is the shell's part: langid names the language of both texts, and when both
# are confident and differ (Polish in, English out - the script check cannot see a switch within
# the Latin alphabet), their names go to the Perl helper, which reports it if "language" is on.
transform_check() {   # $1 = source file, $2 = result file, $3 = output file, [$4 = preset file]
    local _checks=""
    [ -n "${4:-}" ] && _checks="$(preset_get "$4" checks | /usr/bin/tr -cd 'a-z -')"
    local _src_lang=$(transform_text_language "$1")
    local _res_lang=$(transform_text_language "$2")
    local _src_name="" _res_name=""
    if [ -n "$_src_lang" ] && [ -n "$_res_lang" ] && [ "$_src_lang" != "$_res_lang" ]; then
        _src_name="$(transform_language_name "$_src_lang")"
        _res_name="$(transform_language_name "$_res_lang")"
    fi
    /usr/bin/perl "$SCRIPTS_DIR/transform_check.pl" ${_checks:+--checks "$_checks"} \
        ${_src_name:+--language-change "$_src_name" "$_res_name"} \
        "$1" "$2" > "$3" 2>/dev/null || : > "$3"
}

# Fill the Transform picker from the bundled presets and select the saved one (defaults key
# TransformPreset, by preset id), falling back to the first. A transform with several variants is
# listed once, by its first file. A parallel `presetfiles` index in the spool maps the picker's
# 1-based index back to that file. Selects the transform (see select_transform). The programmatic
# sets run inside a quiet window that interp.transform.preset.changed honors, the same guard the
# model picker uses.
populate_preset_picker() {   # $1 = spool
    local _spool="$1" _f _name _id
    local _opts="[" _first=1 _seen=","
    : > "$_spool/presetfiles.tmp"
    for _f in "$PRESETS_DIR"/*.json; do
        [ -f "$_f" ] || continue
        _name="$(preset_get "$_f" name | /usr/bin/tr -d '"\\')"
        [ -n "$_name" ] || continue
        _id="$(preset_get "$_f" id)"
        if [ -n "$_id" ]; then
            case "$_seen" in *",$_id,"*) continue ;; esac
            _seen="$_seen$_id,"
        fi
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
    [ -n "$_sel" ] && select_transform "$_spool" "$_sel"
}

# Make a transform the window's current one, on the model last picked for it when that model is
# installed (else the current model when the transform runs on it; else the poller picks, as for a
# new window), and on the variant made for that model's family.
select_transform() {   # $1 = spool, $2 = preset file (any variant of the transform)
    local _spool="$1"
    local _dirs="$(list_preset_model_dirs "$2")"
    local _cur="$(/bin/cat "$_spool/model.dir" 2>/dev/null)"
    local _key="$(transform_model_pref_key "$2")"
    local _saved=""
    [ -n "$_key" ] && _saved="$("$defaults_tool" read "$BUNDLE_ID" "$_key" 2>/dev/null)"
    local _want=""
    [ -n "$_saved" ] && _want="$(/usr/bin/printf '%s\n' "$_dirs" | /usr/bin/awk -F/ -v n="$_saved" '$NF==n { print; exit }')"
    if [ -z "$_want" ] && [ -n "$_cur" ]; then
        _want="$(/usr/bin/printf '%s\n' "$_dirs" | /usr/bin/grep -Fx -- "$_cur" | /usr/bin/head -1)"
    fi

    local _var=""
    [ -n "$_want" ] && _var="$(preset_variant_for_family "$2" "$(transform_family_of "$_want")")"
    [ -n "$_var" ] || _var="$(preset_variants "$2" | /usr/bin/head -1)"
    apply_preset "$_spool" "${_var:-$2}"
    if [ -n "$_want" ] && [ "$_want" != "$_cur" ]; then
        /usr/bin/printf '%s' "$_want" > "$_spool/model.dir.tmp" && /bin/mv "$_spool/model.dir.tmp" "$_spool/model.dir"
    fi
}

# Keep the window's preset on the variant made for the selected model's family: after the user
# picks a model of another family, or the poller picks one for a new window or after a download.
# Does nothing when the preset already fits, or the transform has no variant for that family.
sync_preset_variant() {   # $1 = spool
    local _model="$(/bin/cat "$1/model.dir" 2>/dev/null)"
    local _preset="$(/bin/cat "$1/preset.file" 2>/dev/null)"
    [ -n "$_model" ] && [ -f "$_preset" ] || return 0
    local _fam="$(transform_family_of "$_model")"
    [ -n "$_fam" ] || return 0
    [ "$(preset_get "$_preset" family)" = "$_fam" ] && return 0
    local _var="$(preset_variant_for_family "$_preset" "$_fam")"
    [ -n "$_var" ] || return 0
    apply_preset "$1" "$_var"
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
    # Document window: the output file is named after the preset, so it follows the switch - to the
    # file this window already wrote for that preset if there is one, else to a fresh name.
    if [ "$(/bin/cat "$1/mode" 2>/dev/null)" = transform-doc ]; then
        refresh_doc_output "$1" "$(transform_output_suffix "$2")"
    fi
}
