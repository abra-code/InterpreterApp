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

# ActionUI control ids (must match interpreter.window.json).
FROM_PICKER=20
TO_PICKER=21
SWAP_BTN=30
TRANSLATE_BTN=40
STOP_BTN=41
COPY_BTN=50
CLEAR_BTN=60
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
    _d=""
    for _d in "$MODELS_DIR"/*translategemma*/ "$MODELS_DIR"/*/; do
        [ -d "$_d" ] || continue
        [ -f "${_d}config.json" ] || continue
        ( cd "$_d" && pwd -P )
        return 0
    done
    return 1
}

model_label_for() { /usr/bin/basename "$1"; }
