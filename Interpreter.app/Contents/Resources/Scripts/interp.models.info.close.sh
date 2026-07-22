# interp.models.info.close - the Close button of the model-details sheet (ModelInfoSheet.json,
# presented window-modally by interp.models.info). Dismissal is the sheet's only action.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"

"$dialog" "$window_uuid" omc_window omc_dismiss_modal

exit 0
