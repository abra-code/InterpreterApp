# interp.models.info - a tier's (i) button in the model chooser. Shows the model's name, its
# HuggingFace download source, where it installs locally, creator credit, and the Gemma license
# notice (which must accompany distribution of a Gemma model derivative - see NOTICE.txt written
# beside the downloaded weights).

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.models.sh"

case "$OMC_ACTIONUI_TRIGGER_VIEW_ID" in
    1006) tier=best ;;
    1016) tier=balanced ;;
    1026) tier=faster ;;
    *) exit 0 ;;
esac

[ -f "$CACHE_DIR/curated.tsv" ] || exit 0
tab=$(/usr/bin/printf '\t')
repo=""; size=""
while IFS="$tab" read -r t r l sz rec heavy desc; do
    [ "$t" = "$tier" ] || continue
    repo="$r"; size="$sz"; break
done < "$CACHE_DIR/curated.tsv"
[ -n "$repo" ] || exit 0

name="TranslateGemma $(model_short_label "$repo")"
url="https://huggingface.co/$HF_AUTHOR/$repo"
dest="$MODELS_DIR/$repo"
if [ -f "$dest/config.json" ]; then
    loc="Installed at:
$dest"
else
    loc="Will download to:
$dest
(about $(bytes_to_gb "$size"))"
fi

msg="Model: $name

Download source:
$url

$loc

Created by Google (TranslateGemma, built on Gemma 3); MLX build by the Hugging Face mlx-community.

License - Gemma Terms of Use:
Gemma is provided under and subject to the Gemma Terms of Use found at ai.google.dev/gemma/terms

Use is also subject to the Gemma Prohibited Use Policy at ai.google.dev/gemma/prohibited_use_policy."

"$dialog" "$window_uuid" omc_window omc_present_alert "Model details" "$msg" "OK::"

exit 0
