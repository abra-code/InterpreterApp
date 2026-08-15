#!/bin/sh
# Tests/lib.test.interp.sh - Interpreter's own test vocabulary, for omctest.
#
# Sourced by every Tests/*.test.sh file, after omctest.sh. omctest supplies the
# generic half - the scratch tree, the interposition directory, the alert and
# omc_dialog_control stubs, check/section/omctest_end - and knows nothing about
# this applet. Everything below is Interpreter's own: where its per-window spool
# lives, how its preferences are read back, and the substitutes its outside
# world answers from.
#
# WHAT IS AND IS NOT COVERED
#
# This applet's work is done by four background scripts - the UI poller, the
# catalog loader, the download-state poller, and the downloader - and by two
# bundled engines. None of them can run under test: the engines load gigabytes
# of weights and the workers are unbounded poll loops that keep writing into the
# window, which would race every assertion in a file rather than merely being
# slow.
#
# So lib.interp.sh names all of them through variables (the seam contract in
# omctest_guide.md section 8), and this file points those variables at
# recorders. What is tested is therefore everything a HANDLER decides: what it
# writes into the window, what it puts in the spool, what it persists, which
# worker it launches and with which arguments, and every guard and error path in
# between. What a worker does once launched is the worker's own contract and is
# NOT covered here - said plainly rather than implied by a green run.
#
# Also not covered, for the same reason it is not covered anywhere: rendering,
# and the actionID-to-COMMAND_ID wiring, which `appletbuilder validate` checks
# statically instead.
#
# POSIX sh only. Validate with "sh -n", never "bash -n".

if [ "${OMCTEST_API_VERSION:-0}" -lt 2 ]; then
    printf 'lib.test.interp: needs omctest API 2 or newer, found %s\n' \
        "${OMCTEST_API_VERSION:-none}" >&2
    exit 1
fi

APP_SCRIPTS="$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts"
APP_RESOURCES="$OMC_APP_BUNDLE_PATH/Contents/Resources"
TEST_HELPERS="$OMCTEST_TESTS/helpers"

# ---------------------------------------------------------------------------
# View ids, imported from the applet rather than restated
# ---------------------------------------------------------------------------
#
# lib.interp.sh writes them bare - MODEL_PICKER=25, SRC_EDITOR=100 - with no
# _ID suffix, so the pattern differs from the one in the omctest guide. A second
# list here is a list that can disagree with the first, and it disagrees
# silently: a name that fails to import expands to the empty string, omc_control
# writes OMC_ACTIONUI_VIEW__VALUE, and every check fails one by one with no hint
# why.
#
# Only bare "NAME=<digits>" lines are taken, so the library's quoted settings
# (GEN_MAXTOK="2048") and its source guard (__INTERP_LIB=1, which does not start
# with a capital) cannot arrive here through the eval.
omctest_import_view_ids() { # <script ...>
    local script
    for script; do
        eval "$(/usr/bin/sed -n \
            -e 's/^\([A-Z][A-Z0-9_]*\)=\([0-9][0-9]*\)$/\1=\2/p' "$script")"
    done
}
omctest_import_view_ids "$APP_SCRIPTS/lib.interp.sh"

for _required in MODEL_PICKER FROM_PICKER TO_PICKER SWAP_BTN TRANSLATE_BTN \
                 STOP_BTN SRC_EDITOR TGT_EDITOR CHAR_TEXT STATUS_TEXT \
                 QL_INPUT QL_OUTPUT INPUT_PATH_TEXT OUTPUT_PATH_TEXT \
                 CHOOSE_OUTPUT_BTN REVEAL_OUTPUT_BTN; do
    eval "_value=\${$_required-}"
    if [ -z "$_value" ]; then
        printf 'lib.test.interp: %s did not import from lib.interp.sh\n' "$_required" >&2
        exit 1
    fi
done
unset _required _value

# The model chooser's section boxes and status views carry no named constant in
# the applet - the handlers spell the numbers out - so these are restated here,
# against models.window.json. The check in 40-models that reads them back out of
# the document is what keeps the two from drifting apart.
SECTION_BEST_ID=1100
SECTION_RECOMMENDED_ID=1200
SECTION_FASTER_ID=1300
CHOOSER_SPINNER_ID=911
CHOOSER_STATUS_ID=910

# ---------------------------------------------------------------------------
# The seam: point the applet's outside world at the fakes
# ---------------------------------------------------------------------------

INTERP_FAKE_DIR="$OMCTEST_WORK/fake"
# The applet's whole library and session state. Redirected because the real one
# holds the developer's downloaded models - tens of gigabytes - and a test that
# wrote there, or worse deleted there, would be operating on their machine.
INTERP_APP_SUPPORT="$OMCTEST_WORK/support"
# Per-run handoff keys. The two window-to-window handoffs travel through the
# login pasteboard server, which outlives every process that touches it, so
# without a prefix two omctest runs share one key - and a path left behind by an
# earlier run has been measured arriving in a later one's document window, which
# then opens on a file nobody asked for. Prefixing is the fix; waiting for the
# value is not, because the stale reading is non-empty and wrong.
INTERP_PB_PREFIX="omctest-$$-"

FAKE_BIN="$OMCTEST_WORK/fakebin"

INTERP_DEFAULTS_TOOL="$FAKE_BIN/defaults"
INTERP_OPEN_TOOL="$FAKE_BIN/open"
INTERP_CURL_TOOL="$FAKE_BIN/curl"
INTERP_SYSCTL_TOOL="$FAKE_BIN/sysctl"
INTERP_AGENT_BIN="$FAKE_BIN/mlx-agent"
INTERP_LLAMA_SERVER_BIN="$FAKE_BIN/llama-server"
INTERP_PDFUTIL_BIN="$FAKE_BIN/pdfutil"
INTERP_POLL_SCRIPT="$FAKE_BIN/interp.poll.sh"
INTERP_MODELS_LOAD_SCRIPT="$FAKE_BIN/interp.models.load.sh"
INTERP_MODELS_POLL_SCRIPT="$FAKE_BIN/interp.models.poll.sh"
INTERP_DOWNLOAD_WORKER_SCRIPT="$FAKE_BIN/interp.download.worker.sh"

export INTERP_FAKE_DIR INTERP_APP_SUPPORT INTERP_PB_PREFIX
export INTERP_DEFAULTS_TOOL INTERP_OPEN_TOOL INTERP_CURL_TOOL INTERP_SYSCTL_TOOL
export INTERP_AGENT_BIN INTERP_LLAMA_SERVER_BIN INTERP_PDFUTIL_BIN
export INTERP_POLL_SCRIPT INTERP_MODELS_LOAD_SCRIPT INTERP_MODELS_POLL_SCRIPT
export INTERP_DOWNLOAD_WORKER_SCRIPT

# Copied rather than symlinked: each fake finds fake_record.sh through
# "dirname $0", and a symlink would resolve that back to Tests/helpers. Copies
# keep the two directories from quietly becoming one.
fakes_install() {
    local tool
    /bin/mkdir -p "$FAKE_BIN" "$INTERP_FAKE_DIR" "$INTERP_APP_SUPPORT"
    /bin/cp "$TEST_HELPERS/fake_record.sh" "$FAKE_BIN/fake_record.sh"
    /bin/cp "$TEST_HELPERS/defaults" "$FAKE_BIN/defaults"
    /bin/chmod +x "$FAKE_BIN/defaults"
    # One recorder body under every name whose only assertable effect is that it
    # was launched. $0's basename decides which log each writes.
    for tool in open curl sysctl mlx-agent llama-server pdfutil \
                interp.poll.sh interp.models.load.sh interp.models.poll.sh \
                interp.download.worker.sh; do
        /bin/cp "$TEST_HELPERS/recorder" "$FAKE_BIN/$tool"
        /bin/chmod +x "$FAKE_BIN/$tool"
    done
}

fakes_reset() {
    /bin/rm -rf "$INTERP_FAKE_DIR"
    /bin/mkdir -p "$INTERP_FAKE_DIR"
}

# ---------------------------------------------------------------------------
# Reading the fakes back
# ---------------------------------------------------------------------------

fake_calls() { # <tool>
    /bin/cat "$INTERP_FAKE_DIR/$1.count" 2>/dev/null || printf '0'
}

fake_argv() { # <tool> [n, default 1]
    /bin/cat "$INTERP_FAKE_DIR/$1.argv.${2:-1}" 2>/dev/null
}

# The <i>th argument (1-based) of the <n>th call. Exact - the argv record, one
# argument per line, not a field of the lossy joined log.
fake_arg_at() { # <tool> <i> [n, default 1]
    fake_argv "$1" "${3:-1}" | /usr/bin/sed -n "${2}p"
}

# yes/no: was <exact-arg> among the arguments of the <n>th call?
#
# An exact line match, not a substring of the joined log: "--lang" is a
# substring of "--language", and a check written against the joined form would
# report a flag the applet never passed.
fake_arg() { # <tool> <exact-arg> [n, default 1]
    if fake_argv "$1" "${3:-1}" | /usr/bin/grep -q -x -F -e "$2"; then
        echo yes
    else
        echo no
    fi
}

fake_mentions() { # <tool> <pattern>
    # A tool that was never called has no log, and grep then prints nothing at
    # all. "expected 0, actual []" is a confusing way to report "it never ran".
    if [ ! -f "$INTERP_FAKE_DIR/$1.log" ]; then
        printf '0'
        return 0
    fi
    /usr/bin/grep -c -- "$2" "$INTERP_FAKE_DIR/$1.log" 2>/dev/null | /usr/bin/tr -d ' '
}

# Wait until <tool> has recorded at least <count> launches.
#
# A handler spawns its background workers with "&" and returns immediately, so
# the fake may not have written its record by the time the next line of a test
# reads it. That is not the applet being slow - it is what backgrounding means -
# so the test waits for the record rather than asserting into a race. Without
# this the count checks pass or fail depending on machine load, which is worse
# than either answer.
wait_for_calls() { # <tool> <count> [timeout-seconds, default 5]
    omc_wait_for "[ \"\$(/bin/cat '$INTERP_FAKE_DIR/$1.count' 2>/dev/null || echo 0)\" -ge $2 ]" \
        "${3:-5}"
}

# A live process whose argv looks like the download worker, for the liveness
# check that guards against a second click starting a second download. The check
# is "ps -o args= matches *interp.download.worker.sh*", so the process really has
# to be running a script of that name - hence a script rather than a renamed
# sleep or an "exec -a" trick, which is a bashism and not portable to the
# POSIX-mode shell these tests are validated against.
#
# Sets FAKE_WORKER_PID in the CALLER's shell; the caller owns the process and
# must kill it. Deliberately not "prints the pid": a command substitution runs
# in a subshell, and a job backgrounded there does not survive to be inspected
# by the time the next line reads it - which would leave the liveness check
# looking at a dead pid and passing for the opposite of the stated reason.
spawn_fake_worker() {
    local script="$FAKE_BIN/live.interp.download.worker.sh"
    # NOT "exec /bin/sleep": exec replaces the shell's argv with the sleep's,
    # and a process whose argv names the worker script is the whole point -
    # download_worker_alive matches on argv so that a recycled pid is never
    # mistaken for a live download.
    printf '#!/bin/sh\n/bin/sleep 30\n' > "$script"
    /bin/chmod +x "$script"
    /bin/sh "$script" >/dev/null 2>&1 &
    FAKE_WORKER_PID=$!
}

# Script the exit code and stdout of a recorder-backed tool.
fake_answer() { # <tool> <rc> [stdout]
    printf '%s' "$2" > "$INTERP_FAKE_DIR/$1.rc"
    printf '%s' "${3:-}" > "$INTERP_FAKE_DIR/$1.out"
}

# How much RAM the fake machine has, for the RAM-aware model curation. Fixed by
# the test rather than read from the Mac running it, or the same suite would
# curate different cards on different machines.
machine_ram_gb() { # <whole gigabytes>
    fake_answer sysctl 0 "$(( $1 * 1024 * 1024 * 1024 ))"
}

# ---------------------------------------------------------------------------
# The applet's own state
# ---------------------------------------------------------------------------

app_support()  { printf '%s' "$INTERP_APP_SUPPORT"; }
models_dir()   { printf '%s/Models' "$INTERP_APP_SUPPORT"; }
sessions_dir() { printf '%s/Sessions' "$INTERP_APP_SUPPORT"; }
cache_dir()    { printf '%s/Cache' "$INTERP_APP_SUPPORT"; }
downloads_dir(){ printf '%s/Downloads' "$INTERP_APP_SUPPORT"; }

# lib.interp.sh: spool_dir_for() is "$SESSIONS_DIR/$window_uuid" - a plain
# concatenation with no TMPDIR in it, so there is no trailing-slash hazard here.
# Recomputed the way the applet computes it, interpolating the uuid, so a change
# to the applet's naming shows up as a missing file rather than as a check
# quietly asserting about a directory nobody writes.
spool_dir() { printf '%s/%s' "$(sessions_dir)" "$OMC_ACTIONUI_WINDOW_UUID"; }

# The chooser window's marker directory, which bounds its poller's lifetime.
chooser_marker() { printf '%s/.chooser.%s' "$(downloads_dir)" "$OMC_ACTIONUI_WINDOW_UUID"; }

spool_file() { /bin/cat "$(spool_dir)/$1" 2>/dev/null; }

# Every value written to a view, in order, one per line - from the journal, not the
# last-write-wins mirror ui_value reads. A QuickLook reload is a SEQUENCE, "" and then the path,
# because the element ignores a source it already holds; the mirror shows the same final path
# either way and so cannot tell a forced reload from a write that changed nothing.
ui_writes() { # <view-id>
    /usr/bin/awk -F'\t' -v id="$1" '$2 == id { sub(/ +$/, "", $3); print $3 }' \
        "$OMCTEST_UI/journal.tsv" 2>/dev/null
}

langcodes()     { spool_file langcodes; }
langcodes_all() { spool_file langcodes.all; }
langfamily()    { spool_file langfamily; }
model_dir_of()  { spool_file model.dir; }
input_path()    { spool_file input.path; }
output_path()   { spool_file output.path; }
job_json()      { spool_file job.json; }

# The source text a published job points at - a per-epoch file, so a rapid
# re-dispatch can never pair one job's text with another job's metadata.
job_source_text() {
    local file
    file="$(job_json | /usr/bin/sed -n 's/.*"text_file":"\([^"]*\)".*/\1/p')"
    [ -n "$file" ] || return 0
    spool_file "$file"
}

job_field() { # <json key>
    job_json | /usr/bin/sed -n "s/.*\"$1\":\\([0-9][0-9]*\\).*/\\1/p"
}

# yes/no: does the published job contain <pattern>? A regex over the raw JSON,
# which is what several of these assertions are actually about - the prompt
# template a family is given is a literal string, and getting it wrong
# mistranslates rather than failing.
job_says() { # <pattern>
    if job_json | /usr/bin/grep -q -- "$1"; then echo yes; else echo no; fi
}

# --- preferences ---------------------------------------------------------------

# Read a preference back through the same fake the applet wrote it with, rather
# than by parsing the store file here: a change to how the fake stores things
# then breaks in one place instead of silently answering wrong.
pref() { # <key>
    "$INTERP_DEFAULTS_TOOL" read com.abracode.Interpreter "$1" 2>/dev/null
}

pref_set() { # <key> <value>
    "$INTERP_DEFAULTS_TOOL" write com.abracode.Interpreter "$1" "$2"
}

# --- pasteboard ------------------------------------------------------------------
#
# The real tool, reached through the interposition directory as the handlers
# reach it. These two keys are GLOBAL, not per-window: a value left behind by
# one section would answer the next section's question, which is why
# reset_document clears both.
pb_get() { "$OMC_OMC_SUPPORT_PATH/pasteboard" "$1" get 2>/dev/null; }
pb_set() { "$OMC_OMC_SUPPORT_PATH/pasteboard" "$1" set "$2"; }

doc_handoff()     { pb_get "${INTERP_PB_PREFIX}INTERP_DOC_INPUT_PATH"; }
service_handoff() { pb_get "${INTERP_PB_PREFIX}INTERP_SERVICE_TEXT_FILE"; }

# ---------------------------------------------------------------------------
# Calling into the applet's libraries
# ---------------------------------------------------------------------------

# Run a library function in a subshell with both libraries loaded.
#
# The subshell keeps the libraries' globals out of the test file and stops a
# function that calls exit from taking the whole file with it. Arguments are
# expanded by the CALLING shell, so a call that has to name one of the
# libraries' own constants needs interp_eval instead.
interp_call() { # <function> [argument ...]
    (
        . "$APP_SCRIPTS/lib.interp.sh" >/dev/null 2>&1
        . "$APP_SCRIPTS/lib.interp.models.sh" >/dev/null 2>&1
        "$@"
    )
}

interp_eval() { # <shell-text evaluated inside the subshell>
    (
        . "$APP_SCRIPTS/lib.interp.sh" >/dev/null 2>&1
        . "$APP_SCRIPTS/lib.interp.models.sh" >/dev/null 2>&1
        eval "$1"
    )
}

# yes/no for a library function that answers a question by exit status.
#
# It answers "no" for a library that fails to load too, so a check whose
# expected value happens to BE "no" could pass on a broken library. Every such
# check in this suite is paired with its opposite, which cannot pass that way.
interp_is() { # <function> [argument ...]
    if interp_call "$@" >/dev/null 2>&1; then echo yes; else echo no; fi
}

# Does the first string contain the second? A function rather than an inline
# case, and not by preference: a case pattern's ")" terminates a $( ) command
# substitution in bash 3.2, so the obvious one-liner is a PARSE ERROR inside the
# substitution rather than a wrong answer.
contains() { # <haystack> <needle> -> yes | no
    case "$1" in
        *"$2"*) echo yes ;;
        *) echo no ;;
    esac
}

# ---------------------------------------------------------------------------
# Fixtures, synthesized rather than committed
# ---------------------------------------------------------------------------

# An installed MLX model: a directory with a config.json, which is the shape
# model_installed_at recognizes. Nothing here is a real model - no handler under
# test ever loads one.
make_mlx_model() { # <dir-name> -> prints the path
    local dir="$(models_dir)/$1"
    /bin/rm -rf "$dir"
    /bin/mkdir -p "$dir"
    printf '{"model_type":"gemma3"}\n' > "$dir/config.json"
    printf '%s' "$dir"
}

# An installed GGUF model: a directory holding a single .gguf file, which is the
# other shape model_installed_at recognizes. The two must stay
# indistinguishable to everything above them, which is what the checks compare.
make_gguf_model() { # <dir-name> -> prints the path
    local dir="$(models_dir)/$1"
    /bin/rm -rf "$dir"
    /bin/mkdir -p "$dir"
    printf 'GGUF\n' > "$dir/weights-Q4_K_M.gguf"
    printf '%s' "$dir"
}

# A directory under Models that is NOT an installed model - a half-finished
# download, say. Everything that enumerates models has to skip it.
make_empty_model_dir() { # <dir-name> -> prints the path
    local dir="$(models_dir)/$1"
    /bin/rm -rf "$dir"
    /bin/mkdir -p "$dir"
    printf '%s' "$dir"
}

make_text_file() { # <name> <contents> -> prints the path
    local file="$OMCTEST_WORK/$1"
    printf '%s' "$2" > "$file"
    printf '%s' "$file"
}

# Assert-then-wipe. ui_reset DELETES unknown_ids.log, suspect_writes.log and
# errors.log, so a single check at the end of a file only ever sees whatever the
# last section wrote - which is how a suite ends up with a standing check that
# reads as coverage and is inert. Checking here, immediately before the wipe,
# makes every section covered by exactly one check, and the one at the end of
# the file covers the final section.
# The model chooser's cards do not exist in any document: they are built at
# runtime with omc_insert_element from model.card.template.json, whose ids are
# __ID_*__ placeholders resolved to 2000 + row*10 + offset. The harness extracts
# known ids from the bundle's ActionUI documents, so every legitimate per-card
# write is "undeclared" and the raw check would be red for the applet working
# correctly.
#
# Card ids are therefore excluded BY RANGE rather than the whole check being
# dropped: interp_card_base_id starts at 2000 and nothing in the four shipped
# documents is numbered that high (the highest is 4020, in the info sheet, which
# stays covered because it is below the guard - see the id list at the top of
# this file). A typo'd id in a fixed window is still caught.
# How many cards the chooser currently has, from the curated list the applet
# builds them from. Used to bound the id exclusion above to rows that really
# exist, rather than blanking the whole 2000-2999 range.
card_rows() {
    if [ -f "$(cache_dir)/curated.tsv" ]; then
        /usr/bin/grep -c '' "$(cache_dir)/curated.tsv"
    else
        printf '0'
    fi
}

ui_hygiene_check() {
    check "no writes to a view id the window does not declare" "" \
        "$(ui_unknown_writes | /usr/bin/awk -v rows="$(card_rows)" '
            {
                if ($1 >= 2000 && $1 <= 2999 && int(($1 - 2000) / 10) <= rows) next
                print
            }')"
    check "no bare value write clobbered a table" "" "$(ui_suspect_writes)"
    check "the harness detected no misuse" "" "$(ui_errors)"
}

# ---------------------------------------------------------------------------
# Resetting between sections
# ---------------------------------------------------------------------------

# Put everything back to a freshly-opened window: this window's spool, the whole
# app-support tree, the fake world, the recorded window writes, and the alert,
# notification and chain records.
#
# The pasteboard clear is not optional. Both handoff keys are global and live in
# the per-login server, which outlives the process, so a path left there by an
# earlier section silently opens the next section's document window on a file it
# never asked for.
#
# Chain history is cumulative across the whole file, so a section asserting "the
# handler did not chain" would otherwise inherit an earlier section's legitimate
# chain.
reset_document() {
    # First, before anything is removed: card_rows reads the curated list the
    # section just used, and the wipe below deletes it.
    ui_hygiene_check
    /bin/rm -rf "$INTERP_APP_SUPPORT"
    /bin/mkdir -p "$(models_dir)" "$(sessions_dir)" "$(cache_dir)" "$(downloads_dir)"
    pb_set "${INTERP_PB_PREFIX}INTERP_DOC_INPUT_PATH" ""
    pb_set "${INTERP_PB_PREFIX}INTERP_SERVICE_TEXT_FILE" ""
    pb_set "interp_epoch_${OMC_ACTIONUI_WINDOW_UUID}" ""
    fakes_reset
    omc_object ""
    ui_reset
    alerts_reset
    alert_answers_reset
    chains_reset
}

# Same, but keeping the preferences and the installed models - "the developer
# closed the window and opened a new one". A section about a setting surviving
# has to use this: reset_document would delete the very thing it means to
# assert had survived, and the check would read as a bug in the applet.
reset_window() {
    ui_hygiene_check
    /bin/rm -rf "$(spool_dir)" "$(chooser_marker)"
    pb_set "${INTERP_PB_PREFIX}INTERP_DOC_INPUT_PATH" ""
    pb_set "${INTERP_PB_PREFIX}INTERP_SERVICE_TEXT_FILE" ""
    pb_set "interp_epoch_${OMC_ACTIONUI_WINDOW_UUID}" ""
    ui_reset
    alerts_reset
    alert_answers_reset
    chains_reset
}

fakes_install
