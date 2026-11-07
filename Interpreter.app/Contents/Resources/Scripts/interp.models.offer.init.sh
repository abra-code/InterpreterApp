# interp.models.offer.init - fired when the chooser the app opened by itself loads: the chooser's
# init with INTERP_CHOOSER_OFFER set, so it fetches nothing from Hugging Face until the user
# clicks Show Models (interp.models.refresh). No one has asked for the network yet.

INTERP_CHOOSER_OFFER=1
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/interp.models.init.sh"
