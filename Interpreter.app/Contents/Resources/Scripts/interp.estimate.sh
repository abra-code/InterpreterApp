# interp.estimate - the Estimate Time button, in all four windows. Says how long the job would take
# for the current text (text windows) or document (document windows), from the speed measured on
# this Mac (Speeds.tsv, lib.interp.load.sh), without loading anything. Only a model never measured
# here is loaded for the answer: the request then queues like a job (estimate.next), and the poller
# answers once the model is loaded.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"

spool=$(spool_dir_for "$window_uuid")
[ -d "$spool" ] || exit 0

is_transform=0
if [ -f "$spool/preset.file" ]; then
    is_transform=1
    source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.transform.sh"
fi

model_dir=$(/bin/cat "$spool/model.dir" 2>/dev/null)
if [ -z "$model_dir" ] || [ ! -d "$model_dir" ]; then
    set_status "Choose a model first."
    exit 0
fi

# Re-entry guard, shared with the run buttons: one request at a time from this window.
/bin/mkdir "$spool/dispatch.lock" 2>/dev/null || exit 0
trap '/bin/rmdir "$spool/dispatch.lock" 2>/dev/null' EXIT
# A request of this window already waits (the poller turns the button off then; this covers the
# moment before it does).
[ -f "$spool/job.next.json" ] && exit 0
[ -f "$spool/estimate.next" ] && exit 0

# Characters to estimate for. A document is converted the quick way (textutil, or a PDF's text
# layer): a scanned PDF is read with OCR only when it is run, which can take minutes, so it has no
# count here.
chars=""
inp=$(/bin/cat "$spool/input.path" 2>/dev/null)
if [ -n "$inp" ]; then
    conv="$spool/estimate.plain.txt"
    convert_to_plain_text "$inp" "$conv"
    convert_rc=$?
    if [ "$convert_rc" -ne 0 ]; then
        set_status "Could not count this document's text. A scanned PDF is read with OCR when it is run, which also takes time."
        exit 0
    fi
    chars=$(LC_ALL=en_US.UTF-8 /usr/bin/wc -m < "$conv" | /usr/bin/tr -d ' ')
    /bin/rm -f "$conv"
else
    chars=$(/usr/bin/printf '%s' "$OMC_ACTIONUI_VIEW_100_VALUE" | LC_ALL=en_US.UTF-8 /usr/bin/wc -m | /usr/bin/tr -d ' ')
fi
case "$chars" in ''|*[!0-9]*) chars=0 ;; esac
if [ "$chars" -eq 0 ]; then
    if [ -n "$inp" ]; then
        set_status "This document has no text to estimate."
    else
        set_status "Type or paste some text to estimate."
    fi
    exit 0
fi

key=$(job_speed_key "$spool" "$model_dir")
loaded=0
[ "$(spool_broker_model "$spool")" = "$model_dir" ] && loaded=1
sentence=$(estimate_sentence "$chars" "$model_dir" "$key" "$loaded")
if [ -n "$sentence" ]; then
    set_status "$sentence"
    exit 0
fi

# Loaded before, but its engine reported no speed at load (the llama-server path): loading it
# again would measure nothing new, so say so instead of loading it.
load_secs=$(speed_get model "$(/usr/bin/basename "$model_dir")" 4)
case "$load_secs" in
    ''|*[!0-9]*) ;;
    *)
        if [ "$loaded" = 1 ]; then
            set_status "The model is loaded. Its speed is measured during the first run, so there is no estimate yet."
        else
            set_status "This model's speed is measured during its first run, so there is no estimate yet. Loading it takes about $(format_duration "$load_secs")."
        fi
        exit 0 ;;
esac

# Never measured on this Mac: load the model to measure it, through the queue and the memory
# budget like any job.
if [ "$is_transform" = 1 ]; then
    model_label=$(transform_display_label "$model_dir")
else
    model_label=$(model_display_label "$model_dir")
fi
confirm_job_start "$spool" "$model_dir" "$model_label"
confirm_rc=$?
if [ "$confirm_rc" -ne 0 ]; then
    set_status "Cancelled."
    exit 0
fi

disable_ctrl "$TRANSLATE_BTN"
disable_ctrl "$ESTIMATE_BTN"
enable_ctrl "$STOP_BTN"
/usr/bin/printf '%s' "$model_dir" > "$spool/job.next.model"
/bin/rm -f "$spool/job.notice"
/usr/bin/printf '%s' "$chars" > "$spool/estimate.next"
queue_enqueue "$spool" "Speed check of $model_label"

if [ "$JOB_QUEUED_BEHIND" = 1 ]; then
    set_status "Waiting for another window to finish..."
else
    set_status "Loading the model to measure its speed..."
fi

exit 0
