# interp.clear - empty both panes and reset the character counter.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"

/usr/bin/printf '' | "$dialog" "$window_uuid" "$SRC_EDITOR" omc_set_value_from_stdin plain
/usr/bin/printf '' | "$dialog" "$window_uuid" "$TGT_EDITOR" omc_set_value_from_stdin plain
"$dialog" "$window_uuid" "$CHAR_TEXT" "0 characters"

exit 0
