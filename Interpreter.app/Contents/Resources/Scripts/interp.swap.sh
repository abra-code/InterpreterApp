# interp.swap - swap the From/To languages and, when there is a translation, swap the pane
# contents too (the translation becomes the new source). When the target pane is empty, only
# the languages swap.
#
# The swap goes by language CODE: the From list has "Detect language" in front, so the same
# language sits one row lower in From than in To. With Detect language chosen there is no From
# language to move down, so the source text's language is detected first; if it cannot be named,
# nothing is swapped and the status line says why.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"

src="$OMC_ACTIONUI_VIEW_100_VALUE"
tgt="$OMC_ACTIONUI_VIEW_200_VALUE"
from_idx="$OMC_ACTIONUI_VIEW_20_VALUE"
to_idx="$OMC_ACTIONUI_VIEW_21_VALUE"

spool=$(spool_dir_for "$window_uuid")
from_code=$(resolve_from_code "$spool" "$from_idx")
to_code=$(resolve_lang_code "$spool" "$to_idx")
[ -n "$from_code" ] && [ -n "$to_code" ] || exit 0

if [ "$from_code" = "$DETECT_CODE" ]; then
    if [ -z "$src" ]; then
        set_status "There is no text to detect the language of. Choose the From language to swap."
        exit 0
    fi
    /usr/bin/printf '%s' "$src" > "$spool/swap.detect.txt"
    from_code=$(detect_source_language "$spool" "$to_code" "$spool/swap.detect.txt")
    detect_rc=$?
    /bin/rm -f "$spool/swap.detect.txt"
    if [ "$detect_rc" -ne 0 ]; then
        set_status "$from_code"
        exit 0
    fi
fi

new_from_idx=$(from_code_index "$spool" "$to_code")
new_to_idx=$(lang_code_index "$spool" "$from_code")
case "$new_from_idx" in ''|*[!0-9]*) exit 0 ;; esac
case "$new_to_idx" in ''|*[!0-9]*) exit 0 ;; esac
"$dialog" "$window_uuid" "$FROM_PICKER" "$new_from_idx"
"$dialog" "$window_uuid" "$TO_PICKER" "$new_to_idx"

# Swap pane contents only when there is a translation to move up.
if [ -n "$tgt" ]; then
    /usr/bin/printf '%s' "$tgt" | "$dialog" "$window_uuid" "$SRC_EDITOR" omc_set_value_from_stdin plain
    /usr/bin/printf '%s' "$src" | "$dialog" "$window_uuid" "$TGT_EDITOR" omc_set_value_from_stdin plain
fi

# Persist the swapped language preferences (as codes; indices shift between family lists).
"$defaults_tool" write "$BUNDLE_ID" FromLang "$to_code"
"$defaults_tool" write "$BUNDLE_ID" ToLang "$from_code"

exit 0
