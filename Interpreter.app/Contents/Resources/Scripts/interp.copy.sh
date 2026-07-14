# interp.copy - put the translation (target editor) on the clipboard.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"

/usr/bin/printf '%s' "$OMC_ACTIONUI_VIEW_200_VALUE" | /usr/bin/pbcopy

exit 0
