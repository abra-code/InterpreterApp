# interp.models.done - close the model chooser window (Done button). Any in-progress download
# keeps running in the background; the main window's Model picker picks up the new model when it
# finishes. Fires END_CANCEL_SUBCOMMAND_ID (interp.models.cancel).

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"

"$dialog" "$window_uuid" omc_window omc_terminate_cancel

exit 0
