# interp.models.info - a card's (i) button in the model chooser. Shows the model's name, its
# HuggingFace download source, where it installs locally, creator credit and per-family
# guidance, and the license notice: the Gemma families share the mandatory Gemma terms text
# (which must accompany distribution of a Gemma model derivative - see NOTICE.txt written
# beside the downloaded weights); Hy-MT2 is Apache 2.0.

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
    milmmt) credit="Created by Xiaomi (MiLMMT-46, built on Google Gemma 3)."; build="MLX build" ;;
    hymt)   credit="Created by Tencent (Hy-MT2)."; build="GGUF build (runs on the bundled llama.cpp)" ;;
    *)      credit="Created by Google (TranslateGemma, built on Gemma 3)."; build="MLX build" ;;
esac
case "$fam" in
    hymt) license="License - Apache License 2.0:
This model is distributed under the Apache License, Version 2.0 - see apache.org/licenses/LICENSE-2.0" ;;
    *)    license="License - Gemma Terms of Use:
Gemma is provided under and subject to the Gemma Terms of Use found at ai.google.dev/gemma/terms

Use is also subject to the Gemma Prohibited Use Policy at ai.google.dev/gemma/prohibited_use_policy." ;;
esac

# A gguf row's real repo comes from the catalog's gguf_file column ("repo/file.gguf" form);
# the curated repo column is then only the local install name.
hf_name="$repo"
gf=$(/usr/bin/awk -F"$tab" -v a="$author" -v n="$repo" \
    '/^[[:space:]]*#/ { next } $2==a && $3==n && $6=="gguf" { print $7; exit }' "$INTERP_CATALOG_TSV")
case "$gf" in */*) hf_name="${gf%%/*}" ;; esac
url="https://huggingface.co/$author/$hf_name"

dest="$MODELS_DIR/$repo"
if model_installed_at "$dest"; then
    loc="Installed at:
$dest"
else
    loc="Will download to:
$dest
(about $(bytes_to_gb "$size"))"
fi

msg="Model: $label

$(family_blurb "$fam")

Download source:
$url

$loc

$credit $build from the Hugging Face repository above.

$license"

present_alert "Model details" "$msg"

exit 0
