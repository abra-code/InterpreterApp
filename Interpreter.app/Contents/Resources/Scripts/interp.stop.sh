# interp.stop - request cancellation of the current translation. The map broker checks the
# stop flag between and during chunks; the poller reflects the resulting "cancelled" state.
# A document conversion can also be inside the page-by-page OCR fallback (pdf_extract_text)
# when Stop is clicked: the convert.cancel flag stops the loop at the next page boundary, and
# the currently recorded pdfutil child (ocr.pid) is killed too - argv-verified, so a recycled
# pid is never signalled - so at most one page of OCR work is lost. The flag is written FIRST
# so the waiting handler reports "Cancelled" rather than an OCR failure; interp.doc.translate
# clears it at the start of each run.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"

spool=$(spool_dir_for "$window_uuid")
[ -d "$spool" ] || exit 0

/usr/bin/touch "$spool/convert.cancel"
ocr_pid=$(/bin/cat "$spool/ocr.pid" 2>/dev/null)
case "$ocr_pid" in
    ''|*[!0-9]*) ;;
    *)
        case "$(/bin/ps -p "$ocr_pid" -o args= 2>/dev/null)" in
            "$PDFUTIL_BIN"|"$PDFUTIL_BIN "*) /bin/kill -TERM "$ocr_pid" 2>/dev/null ;;
        esac ;;
esac

/usr/bin/touch "$spool/stop"
set_status "Stopping…"

exit 0
