# interp.to.changed - persist the To-language selection (1-based picker index). Guard the
# value: programmatic option/value updates can fire this with a transitional/bogus value.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"

idx="$OMC_ACTIONUI_VIEW_21_VALUE"
case "$idx" in ''|*[!0-9]*) exit 0 ;; esac
/usr/bin/defaults write "$BUNDLE_ID" ToIndex "$idx"

exit 0
