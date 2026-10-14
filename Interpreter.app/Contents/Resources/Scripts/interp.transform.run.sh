# interp.transform.run - the Rewrite button (Cmd-Return). Publishes the editor's text as a job for
# the window's broker, built from the current preset; the poller reflects progress, pushes the
# result into the right-hand editor, and runs the fact check when it finishes.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.transform.sh"

src="$OMC_ACTIONUI_VIEW_100_VALUE"
[ -n "$src" ] || exit 0

spool=$(spool_dir_for "$window_uuid")
[ -d "$spool" ] || exit 0

# Same re-entry guard as interp.translate: button and shortcut are two trigger paths.
/bin/mkdir "$spool/dispatch.lock" 2>/dev/null || exit 0
trap '/bin/rmdir "$spool/dispatch.lock" 2>/dev/null' EXIT

disable_ctrl "$TRANSLATE_BTN"
enable_ctrl "$STOP_BTN"

nchars=$(/usr/bin/printf '%s' "$src" | LC_ALL=en_US.UTF-8 /usr/bin/wc -m | /usr/bin/tr -d ' ')
"$dialog" "$window_uuid" "$CHAR_TEXT" "$nchars characters"
/usr/bin/printf '' | "$dialog" "$window_uuid" "$TGT_EDITOR" omc_set_value_from_stdin plain
"$dialog" "$window_uuid" "$CHECK_TEXT" ""

preset="$(/bin/cat "$spool/preset.file" 2>/dev/null)"
if [ -z "$preset" ] || [ ! -f "$preset" ]; then
    enable_ctrl "$TRANSLATE_BTN"; disable_ctrl "$STOP_BTN"
    set_status "Choose a transform first."
    exit 0
fi

/usr/bin/printf '%s' "$src" | publish_transform_job "$spool" "$preset"
rc=$?
if [ "$rc" -ne 0 ]; then
    enable_ctrl "$TRANSLATE_BTN"; disable_ctrl "$STOP_BTN"
    set_status "Could not prepare the job for this transform."
    exit 0
fi

set_status "Rewriting..."

exit 0
