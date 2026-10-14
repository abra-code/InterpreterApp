# interp.tdoc.run - the document window's Rewrite. The transform twin of interp.doc.translate:
# settles the output file for the current preset, converts the document to plain text (textutil;
# PDFs through the page ladder with Vision OCR for scanned pages - no language hint here, so OCR
# detects the language itself), and publishes the text as a job built from the preset. The poller
# writes the finished result to the output file and runs the fact check.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.transform.sh"

spool=$(spool_dir_for "$window_uuid")
[ -d "$spool" ] || exit 0

inp="$(/bin/cat "$spool/input.path" 2>/dev/null)"
if [ -z "$inp" ] || [ ! -e "$inp" ]; then
    set_status "No input document."
    exit 0
fi

# Re-entry guard (button and Cmd-Return are two trigger paths). Released on any exit.
/bin/mkdir "$spool/dispatch.lock" 2>/dev/null || exit 0
trap '/bin/rmdir "$spool/dispatch.lock" 2>/dev/null' EXIT

disable_ctrl "$TRANSLATE_BTN"
enable_ctrl "$STOP_BTN"
"$dialog" "$window_uuid" "$CHECK_TEXT" ""

preset="$(/bin/cat "$spool/preset.file" 2>/dev/null)"
if [ -z "$preset" ] || [ ! -f "$preset" ]; then
    enable_ctrl "$TRANSLATE_BTN"; disable_ctrl "$STOP_BTN"
    set_status "Choose a transform first."
    exit 0
fi

# The destination for THIS job, captured now (see interp.doc.translate): a preset switch while the
# job runs renames the default output for the next run and must not retarget this write. A settle
# that printed nothing would leave the capture empty and send the poller to the previous output.
set_doc_output "$spool" "$(transform_output_suffix "$preset")" > "$spool/job.output.path"
settle_rc=$?
if [ "$settle_rc" -ne 0 ] || [ ! -s "$spool/job.output.path" ]; then
    enable_ctrl "$TRANSLATE_BTN"; disable_ctrl "$STOP_BTN"
    set_status "Could not decide where to save the result."
    exit 0
fi
disable_ctrl "$REVEAL_OUTPUT_BTN"

/bin/rm -f "$spool/convert.cancel"
conv="$spool/input.plain.txt"
convert_to_plain_text "$inp" "$conv" "$spool" ""
convert_rc=$?

if [ "$convert_rc" -eq 2 ]; then
    enable_ctrl "$TRANSLATE_BTN"; disable_ctrl "$STOP_BTN"
    set_status "Cancelled."
    exit 0
fi
if [ "$convert_rc" -ne 0 ]; then
    enable_ctrl "$TRANSLATE_BTN"; disable_ctrl "$STOP_BTN"
    set_status "Could not read this document."
    present_alert "Can't read this document" "Interpreter could not read this document:

$inp

It may be in a format that is not supported, or the file may be damaged."
    exit 0
fi

/usr/bin/grep -q '[^[:space:]]' "$conv" 2>/dev/null
has_text_rc=$?
if [ "$has_text_rc" -ne 0 ]; then
    enable_ctrl "$TRANSLATE_BTN"; disable_ctrl "$STOP_BTN"
    set_status "No text to rewrite."
    present_alert "Nothing to rewrite" "This document has no readable text to rewrite."
    exit 0
fi

# Reading a scanned PDF can take minutes, and the Transform picker stays live meanwhile. A switch in
# that time has already restarted the broker with the NEW preset's settings (possibly another model
# family), so publishing the OLD preset's job now would run it on the wrong broker and save it under
# the old preset's name. Stop instead; the user's next Rewrite uses the preset now selected.
current_preset="$(/bin/cat "$spool/preset.file" 2>/dev/null)"
if [ "$current_preset" != "$preset" ]; then
    enable_ctrl "$TRANSLATE_BTN"; disable_ctrl "$STOP_BTN"
    set_status "The transform changed while the document was being read. Click Rewrite again."
    exit 0
fi

/bin/cat "$conv" | publish_transform_job "$spool" "$preset"
publish_rc=$?
if [ "$publish_rc" -ne 0 ]; then
    enable_ctrl "$TRANSLATE_BTN"; disable_ctrl "$STOP_BTN"
    set_status "Could not prepare the job for this transform."
    exit 0
fi

set_status "Rewriting..."

exit 0
