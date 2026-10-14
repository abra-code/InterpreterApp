# interp.tmodels.init - fired when the Text Transform model chooser loads. Binds this window to the
# transform library, which ALSO records the window's kind for every later handler: the shared init
# below creates the chooser marker dir under the transform downloads dir, and the library resolves
# a chooser window's kind from where that dir lives. Then retitles the window's header.

source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/lib.interp.sh"

interp_apply_kind transform

"$dialog" "$window_uuid" 900 "Text Transform Models"
"$dialog" "$window_uuid" 901 "Download a model to rewrite text on your Mac. These choices are picked for your Mac's memory; the Recommended section is the best balance of quality and speed."

# The shared chooser init, running on the transform bindings applied above.
source "$SCRIPTS_DIR/interp.models.init.sh"
