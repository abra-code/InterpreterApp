# interp.swap - swap the From/To languages and, when there is a translation, swap the pane
# contents too (the translation becomes the new source). When the target pane is empty, only
# the languages swap.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"

src="$OMC_ACTIONUI_VIEW_100_VALUE"
tgt="$OMC_ACTIONUI_VIEW_200_VALUE"
from_idx="$OMC_ACTIONUI_VIEW_20_VALUE"
to_idx="$OMC_ACTIONUI_VIEW_21_VALUE"

# Swap picker indices (pickers are set by 1-based index).
case "$from_idx" in ''|*[!0-9]*) from_idx="" ;; esac
case "$to_idx" in ''|*[!0-9]*) to_idx="" ;; esac
[ -n "$to_idx" ] && "$dialog" "$window_uuid" "$FROM_PICKER" "$to_idx"
[ -n "$from_idx" ] && "$dialog" "$window_uuid" "$TO_PICKER" "$from_idx"

# Swap pane contents only when there is a translation to move up.
if [ -n "$tgt" ]; then
    /usr/bin/printf '%s' "$tgt" | "$dialog" "$window_uuid" "$SRC_EDITOR" omc_set_value_from_stdin plain
    /usr/bin/printf '%s' "$src" | "$dialog" "$window_uuid" "$TGT_EDITOR" omc_set_value_from_stdin plain
fi

# Persist the swapped language preferences (as codes; indices shift between family lists).
spool=$(spool_dir_for "$window_uuid")
from_code=$(resolve_lang_code "$spool" "$to_idx")
to_code=$(resolve_lang_code "$spool" "$from_idx")
[ -n "$from_code" ] && /usr/bin/defaults write "$BUNDLE_ID" FromLang "$from_code"
[ -n "$to_code" ] && /usr/bin/defaults write "$BUNDLE_ID" ToLang "$to_code"

exit 0
