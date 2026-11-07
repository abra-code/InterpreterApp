# interp.tmodels.offer.init - fired when the Text Transform chooser the app opened by itself
# loads: interp.tmodels.init with INTERP_CHOOSER_OFFER set, so nothing is fetched from Hugging
# Face until the user clicks Show Models (interp.models.refresh).

INTERP_CHOOSER_OFFER=1
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/interp.tmodels.init.sh"
