# interp.doc.translate - translate the input document to the output file. Converts the document to
# plain text with textutil, then hands that text to the shared dispatch (publish_translation_job),
# exactly like the text window's Translate. The poller reflects progress and, on completion, writes
# the translation to the chosen output path and refreshes the right-hand QuickLook.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"

from_idx="$OMC_ACTIONUI_VIEW_20_VALUE"
to_idx="$OMC_ACTIONUI_VIEW_21_VALUE"

spool=$(spool_dir_for "$window_uuid")
[ -d "$spool" ] || exit 0

inp="$(/bin/cat "$spool/input.path" 2>/dev/null)"
if [ -z "$inp" ] || [ ! -e "$inp" ]; then
    set_status "No input document."
    exit 0
fi

# Re-entry guard (Translate button + Cmd+Return are two trigger paths). Released on any exit.
/bin/mkdir "$spool/dispatch.lock" 2>/dev/null || exit 0
trap '/bin/rmdir "$spool/dispatch.lock" 2>/dev/null' EXIT

# Snappy UI transition (the poller also does this once it observes "mapping"). The prior output is
# about to be superseded, so its Reveal affordance no longer points at the current translation.
disable_ctrl "$TRANSLATE_BTN"
enable_ctrl "$STOP_BTN"
disable_ctrl "$REVEAL_OUTPUT_BTN"

# Resolve the picker indices (1-based) to language codes; a stale/bogus index is surfaced.
src_code=$(resolve_lang_code "$spool" "$from_idx")
tgt_code=$(resolve_lang_code "$spool" "$to_idx")
if [ -z "$src_code" ] || [ -z "$tgt_code" ]; then
    enable_ctrl "$TRANSLATE_BTN"; disable_ctrl "$STOP_BTN"
    set_status "Please choose valid From and To languages."
    exit 0
fi

# Convert the document to plain text. A failure here means an unsupported/damaged file.
conv="$spool/input.plain.txt"
if ! convert_to_plain_text "$inp" "$conv"; then
    enable_ctrl "$TRANSLATE_BTN"; disable_ctrl "$STOP_BTN"
    set_status "Could not read this document (unsupported or damaged)."
    exit 0
fi
if ! /usr/bin/grep -q '[^[:space:]]' "$conv" 2>/dev/null; then
    enable_ctrl "$TRANSLATE_BTN"; disable_ctrl "$STOP_BTN"
    set_status "The document has no text to translate."
    exit 0
fi

# Publish the job from the converted text (shared with the text window): bumps the epoch, writes
# the per-epoch source file, builds+publishes job.json, and stamps the dispatch time for timing.
/bin/cat "$conv" | publish_translation_job "$spool" "$src_code" "$tgt_code"

set_status "Translating…"

exit 0
