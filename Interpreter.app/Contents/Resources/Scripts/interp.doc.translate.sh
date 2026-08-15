# interp.doc.translate - translate the input document to the output file. Converts the document to
# plain text (textutil; PDFs via the bundled pdfutil's page-by-page ladder, where scanned
# text-less pages get per-page Vision OCR - see pdf_extract_text in lib.interp.sh), then hands
# that text to the shared dispatch (publish_translation_job), exactly like the text window's
# Translate. The poller reflects progress and, on completion, writes the translation to the
# chosen output path and refreshes the right-hand QuickLook. The OCR runs inline in this
# handler (OMC handlers are async, and dispatch.lock already bars re-entry); Stop stays live
# throughout - the convert.cancel flag stops the page loop and interp.stop also kills the
# in-flight pdfutil child, so a cancel loses at most one page of OCR work.

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

# Snappy UI transition (the poller also does this once it observes "mapping").
disable_ctrl "$TRANSLATE_BTN"
enable_ctrl "$STOP_BTN"

# Resolve the picker indices (1-based) to language codes; a stale/bogus index is surfaced.
src_code=$(resolve_lang_code "$spool" "$from_idx")
tgt_code=$(resolve_lang_code "$spool" "$to_idx")
if [ -z "$src_code" ] || [ -z "$tgt_code" ]; then
    enable_ctrl "$TRANSLATE_BTN"; disable_ctrl "$STOP_BTN"
    set_status "Please choose valid From and To languages."
    exit 0
fi

# The output is named after the language it will be in, so settle the destination against the
# language actually being dispatched (the picker can also have been set programmatically, which
# interp.to.changed deliberately ignores). Capture it for THIS job: a To change made while the
# translation is in flight moves the default name for the NEXT run, and must not silently
# retarget the write the poller is about to make.
# set_doc_output, not refresh_doc_output: the preview is left alone here, so the translation being
# replaced stays on screen while its replacement is made, rather than blinking out at dispatch.
#
# Guarded rather than fired and forgotten: the redirect truncates job.output.path BEFORE the
# producer runs, so a settle that printed nothing would leave an empty capture and send the poller
# back to output.path - the PREVIOUS run's destination, which it would then overwrite. Both inputs
# are validated above, so this cannot fire today; it is written so that it cannot start to.
if ! set_doc_output "$spool" "$tgt_code" > "$spool/job.output.path"; then
    enable_ctrl "$TRANSLATE_BTN"; disable_ctrl "$STOP_BTN"
    set_status "Could not decide where to save the translation."
    exit 0
fi

# The prior output is about to be superseded, so its Reveal affordance no longer points at the
# current translation.
disable_ctrl "$REVEAL_OUTPUT_BTN"

# Convert the document to plain text. convert_to_plain_text judges real readability (textutil's own
# exit status lies - it returns 0 for an unreadable .pages/other package while writing nothing), so
# a non-zero return here means an unsupported or damaged file. Surface that as a modal alert now
# (not just a status-line trace) so the failure is not mistaken later for "no text to translate".
# Fresh run: a cancel flag left by a Stop during a PREVIOUS conversion must not kill this one.
/bin/rm -f "$spool/convert.cancel"

# With the spool and From language, a PDF goes through the page-by-page ladder: scanned
# (text-less) pages get per-page Vision OCR hinted with the From language, with progress in
# the status line and Stop live throughout (rc 2 = the user cancelled - not an error).
conv="$spool/input.plain.txt"
convert_to_plain_text "$inp" "$conv" "$spool" "$src_code"
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

# Guard an empty conversion: a genuinely blank document, or a textutil that exited 0 yet produced
# no usable text. Either way there is nothing to translate - say so in a modal alert.
/usr/bin/grep -q '[^[:space:]]' "$conv" 2>/dev/null
has_text_rc=$?
if [ "$has_text_rc" -ne 0 ]; then
    enable_ctrl "$TRANSLATE_BTN"; disable_ctrl "$STOP_BTN"
    set_status "No text to translate."
    present_alert "Nothing to translate" "This document has no readable text to translate."
    exit 0
fi

# Publish the job from the converted text (shared with the text window): bumps the epoch, writes
# the per-epoch source file, builds+publishes job.json, and stamps the dispatch time for timing.
# Publishing can refuse (a raw-prompt family whose language names cannot be resolved) - restore
# the UI and say so instead of leaving a silent dead Translate.
/bin/cat "$conv" | publish_translation_job "$spool" "$src_code" "$tgt_code"
if [ $? -ne 0 ]; then
    enable_ctrl "$TRANSLATE_BTN"; disable_ctrl "$STOP_BTN"
    set_status "Could not prepare the translation for this model and language pair."
    exit 0
fi

set_status "Translating…"

exit 0
