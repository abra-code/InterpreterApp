# interp.models.info - a card's (i) button in the model chooser. Shows the model's name, its
# HuggingFace download source, where it installs locally, creator credit, and the Gemma license
# notice (which must accompany distribution of a Gemma model derivative - see NOTICE.txt written
# beside the downloaded weights). Both offered families are Gemma derivatives, so the license
# text is shared; the credit line is per family.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.models.sh"

case "$OMC_ACTIONUI_TRIGGER_VIEW_ID" in ''|*[!0-9]*) exit 0 ;; esac
[ "$OMC_ACTIONUI_TRIGGER_VIEW_ID" -gt 2000 ] 2>/dev/null || exit 0
row=$(interp_card_row_of_id "$OMC_ACTIONUI_TRIGGER_VIEW_ID")

[ -f "$CACHE_DIR/curated.tsv" ] || exit 0
tab=$(/usr/bin/printf '\t')
line=$(curated_row "$CACHE_DIR/curated.tsv" "$row")
[ -n "$line" ] || exit 0
sec=""; fam=""; author=""; repo=""; label=""; size=""; heavy=""; desc=""
IFS="$tab" read -r sec fam author repo label size heavy desc <<EOF
$line
EOF
[ -n "$repo" ] || exit 0

case "$fam" in
    milmmt) credit="Created by Xiaomi (MiLMMT-46, built on Google Gemma 3)." ;;
    *)      credit="Created by Google (TranslateGemma, built on Gemma 3)." ;;
esac

url="https://huggingface.co/$author/$repo"
dest="$MODELS_DIR/$repo"
if [ -f "$dest/config.json" ]; then
    loc="Installed at:
$dest"
else
    loc="Will download to:
$dest
(about $(bytes_to_gb "$size"))"
fi

msg="Model: $label

Download source:
$url

$loc

$credit MLX build from the Hugging Face repository above.

License - Gemma Terms of Use:
Gemma is provided under and subject to the Gemma Terms of Use found at ai.google.dev/gemma/terms

Use is also subject to the Gemma Prohibited Use Policy at ai.google.dev/gemma/prohibited_use_policy."

present_alert "Model details" "$msg"

exit 0
