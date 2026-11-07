# Tests/interpreter.itest.sh - Interpreter through the real engine (appletbuilder itest, OMC 5.5).
#
# The omctest suites (*.test.sh) run Interpreter's handlers one at a time with stand-in tools and
# workers; this file launches the applet itself and drives its windows over the bridge, so the
# real launch chain (main command, interp.new, INIT_SUBCOMMAND_ID interp.window.init, the chained
# model chooser), the real UI poller, the private pasteboard handoff to the document window, the
# open and save panels (answered by the test) and the end commands are what is checked.
#
# No model is ever downloaded or run. The applet's $HOME is the test's own, so its model library
# starts empty: the launch shows the first-run state, and the model chooser it opens looks up the
# catalog on Hugging Face (one small query per catalog row, no download;the test cannot stop them, see the
# commit note). The test then puts a model folder in the library that has a config.json and no
# weights: every window picks it up as installed, and mlx-agent refuses it in milliseconds, so the
# windows stay at "Loading model" and Translate is never offered. Nothing is translated.
#
# Not touched: the language pickers and Swap. Their handlers save the choice with /usr/bin/defaults,
# which writes the user's own preferences whatever $HOME says; the last section checks that the
# user's saved languages and model are what they were when this file started (after the launch,
# so a write during the launch itself is not caught).

eval "$(/usr/bin/sed -n 's/^\([A-Z][A-Z_]*\)=\([0-9][0-9]*\)$/\1=\2/p' \
    "$ITEST_APP/Contents/Resources/Scripts/lib.interp.sh")"
check "the view ids imported from lib.interp.sh" "25 20 21 40 300 130 230 231" \
    "$MODEL_PICKER $FROM_PICKER $TO_PICKER $TRANSLATE_BTN $STATUS_TEXT $INPUT_PATH_TEXT $OUTPUT_PATH_TEXT $CHOOSE_OUTPUT_BTN"

SUPPORT="$ITEST_HOME/Library/Application Support/Interpreter"
BUNDLE_ID="com.abracode.Interpreter"

# A view's property as the bridge gives it (JSON).
property() { # <window> <view-id> <name>
    itest_call actionui.getProperty "{\"window\": \"$1\", \"viewID\": $2, \"name\": \"$3\"}"
}
# How many entries a one-line JSON array of strings holds.
entries() { # <json array>
    printf '%s\n' "$1" | /usr/bin/awk -F'", "' '{ print NF }'
}
# Waits up to <seconds> for a view's value to contain <text>; prints the value it last saw.
wait_for_value() { # <window> <view-id> <text> <seconds>
    local _deadline=$(( SECONDS + $4 ))
    local _value=""
    while [ "$SECONDS" -lt "$_deadline" ]; do
        _value="$(itest_value "$1" "$2")"
        case "$_value" in
            *"$3"*) break ;;
        esac
        /bin/sleep 0.25
    done
    printf '%s\n' "$_value"
}
# The same for a property.
wait_for_property() { # <window> <view-id> <name> <text> <seconds>
    local _deadline=$(( SECONDS + $5 ))
    local _value=""
    while [ "$SECONDS" -lt "$_deadline" ]; do
        _value="$(property "$1" "$2" "$3")"
        case "$_value" in
            *"$4"*) break ;;
        esac
        /bin/sleep 0.25
    done
    printf '%s\n' "$_value"
}
# Background processes (UI pollers, catalog loaders, mlx-agent brokers) whose command line names
# <text>: a session folder, or the applet copy for all of them.
workers_on() { # <text>
    /bin/ps -axo command | /usr/bin/grep -F -- "$1" | /usr/bin/grep -c -e 'interp\.[a-z.]*\.sh' -e 'mlx-agent'
}
# Waits up to <seconds> for no worker naming <text> to be left; prints how many there were last.
wait_no_workers() { # <text> <seconds>
    local _deadline=$(( SECONDS + $2 ))
    local _n="$(workers_on "$1")"
    while [ "$_n" != "0" ] && [ "$SECONDS" -lt "$_deadline" ]; do
        /bin/sleep 0.5
        _n="$(workers_on "$1")"
    done
    printf '%s\n' "$_n"
}
# The user's own saved choices (the real preferences, see the header).
user_choices() {
    local _key
    for _key in FromLang ToLang ModelName; do
        printf '%s=%s\n' "$_key" "$(/usr/bin/defaults read "$BUNDLE_ID" "$_key" 2>/dev/null)"
    done
}
choices_before="$(user_choices)"

section "A bare launch with no model opens the translator and the model chooser over it"
# The engine ran the main command at launch: no document, so interp.new; its init found no model
# and chained to interp.models. Each window's state folder says which is which.
translator=""
chooser=""
for w in $(itest_windows); do
    if [ -d "$SUPPORT/Sessions/$w" ]; then translator="$w"; fi
    if [ -d "$SUPPORT/Downloads/.chooser.$w" ]; then chooser="$w"; fi
done
check "two windows at launch" "2" "$(itest_windows | /usr/bin/awk 'END { print NR }')"
check "the translator window opened" "yes" "$([ -n "$translator" ] && printf yes || printf no)"
check "and the model chooser" "yes" "$([ -n "$chooser" ] && printf yes || printf no)"
check_contains "the translator says there is no model" "No translation model" \
    "$(wait_for_value "$translator" "$STATUS_TEXT" "No translation model" 10)"
model_options="$(property "$translator" "$MODEL_PICKER" options)"
check "the Model menu offers only the download" "1" "$(entries "$model_options")"
check_contains "which is Download models" "Download models" "$model_options"
check "Translate is off" "true" "$(property "$translator" "$TRANSLATE_BTN" disabled)"
from_options="$(property "$translator" "$FROM_PICKER" options)"
to_options="$(property "$translator" "$TO_PICKER" options)"
languages="$(/usr/bin/awk -F'\t' '$1 != "" && $2 != "" { n++ } END { print n }' "$ITEST_APP/Contents/Resources/languages.tsv")"
check "To lists every language in languages.tsv" "$languages" "$(entries "$to_options")"
check "From lists them too, after Detect language" "$(( languages + 1 ))" "$(entries "$from_options")"
check_contains "Detect language first" '["Detect language", ' "$from_options"
itest_close "$chooser" > /dev/null
itest_wait_idle
check "closing the chooser closes it" "0" "$(itest_windows | /usr/bin/grep -c -x -- "$chooser")"
check "and its end command removed its state" "no" "$([ -d "$SUPPORT/Downloads/.chooser.$chooser" ] && printf yes || printf no)"

section "A model that appears in the library is picked up by the open window"
# As after a download: the window's poller rescans the library every second. This model has no
# weights, so mlx-agent refuses it and the window keeps waiting for it to load.
/bin/mkdir -p "$SUPPORT/Models/itest-unloadable"
printf '{}\n' > "$SUPPORT/Models/itest-unloadable/config.json"
model_options="$(wait_for_property "$translator" "$MODEL_PICKER" options itest-unloadable 10)"
check "the Model menu lists it" "2" "$(entries "$model_options")"
check_contains "by its folder name" '"itest-unloadable"' "$model_options"
check_contains "the window loads it" "Loading model" "$(wait_for_value "$translator" "$STATUS_TEXT" "Loading model" 10)"
check "Translate stays off" "true" "$(property "$translator" "$TRANSLATE_BTN" disabled)"

section "A document dropped on the app opens the document window"
printf 'Bonjour tout le monde.\n' > "$ITEST_WORK/notes.txt"
before="$(itest_windows)"
itest_run Interpreter --file "$ITEST_WORK/notes.txt" > /dev/null
itest_wait_idle
doc="$(itest_new_window "$before")"
# Counted, not itest_new_window: that prints only the first new window, so it cannot see a chooser.
check "one new window, no chooser this time" "$(( $(printf '%s\n' "$before" | /usr/bin/awk 'END { print NR }') + 1 ))" \
    "$(itest_windows | /usr/bin/awk 'END { print NR }')"
check "the document window took the dropped file" "$ITEST_WORK/notes.txt" "$(itest_value "$doc" "$INPUT_PATH_TEXT")"
to_code="$(/bin/cat "$SUPPORT/Sessions/$doc/to.code" 2>/dev/null)"
check "the output is named for the To language, next to the original" "$ITEST_WORK/notes-$to_code.txt" \
    "$(itest_value "$doc" "$OUTPUT_PATH_TEXT")"
check_contains "it too waits for the model" "Loading model" "$(wait_for_value "$doc" "$STATUS_TEXT" "Loading model" 10)"

section "File > Open asks for the document through the open panel"
itest_panels_clear
before="$(itest_windows)"
itest_answer_cancel
itest_run interp.open > /dev/null
itest_wait_idle
check "an open panel" "open" "$(itest_panel last kind)"
check "with the command's message" "Choose a document to translate" "$(itest_panel last message)"
check "for one document" "false" "$(itest_panel last allowsMultiple)"
check "canceling it opens nothing" "" "$(itest_new_window "$before")"
printf 'Dzien dobry.\n' > "$ITEST_WORK/letter.txt"
itest_answer_open "$ITEST_WORK/letter.txt"
itest_run interp.open > /dev/null
itest_wait_idle
opened="$(itest_new_window "$before")"
check "choosing one opens the document window" "$ITEST_WORK/letter.txt" "$(itest_value "$opened" "$INPUT_PATH_TEXT")"

section "Choose Output asks where to save through the save panel"
itest_answer_save "$ITEST_WORK/chosen.txt"
check "the button fires interp.doc.choose.output" "interp.doc.choose.output" "$(itest_click "$opened" "$CHOOSE_OUTPUT_BTN")"
itest_wait_idle
check "a save panel" "save" "$(itest_panel last kind)"
check "with the command's message" "Save the translation as" "$(itest_panel last message)"
check "the Output field shows the choice" "$ITEST_WORK/chosen.txt" "$(itest_value "$opened" "$OUTPUT_PATH_TEXT")"
check "and the window keeps it" "$ITEST_WORK/chosen.txt" "$(/bin/cat "$SUPPORT/Sessions/$opened/output.path" 2>/dev/null)"
check "nothing is written before a translation" "no" "$([ -e "$ITEST_WORK/chosen.txt" ] && printf yes || printf no)"

section "Closing a window ends its session"
running="$(workers_on "$SUPPORT/Sessions/$opened")"
check "while it is open its poller runs" "yes" "$([ "$running" -gt 0 ] && printf yes || printf no)"
itest_close "$opened" > /dev/null
itest_wait_idle
check "its end command removed its state" "no" "$([ -d "$SUPPORT/Sessions/$opened" ] && printf yes || printf no)"
check "and its poller and broker stopped" "0" "$(wait_no_workers "$SUPPORT/Sessions/$opened" 10)"
check "the other windows keep theirs" "yes yes" \
    "$([ -d "$SUPPORT/Sessions/$doc" ] && printf yes || printf no) $([ -d "$SUPPORT/Sessions/$translator" ] && printf yes || printf no)"

section "Quitting stops every worker"
# app.will.terminate (WAIT_FOR_TASK_COMPLETION) stops the pollers and brokers and removes the
# session folders before the applet exits.
running="$(workers_on "$ITEST_APP/Contents")"
check "before quitting the windows have workers" "yes" "$([ "$running" -gt 0 ] && printf yes || printf no)"
itest_quit
check "the session folders are gone" "no" "$([ -d "$SUPPORT/Sessions" ] && printf yes || printf no)"
check "no poller, loader or broker is left" "0" "$(wait_no_workers "$ITEST_APP/Contents" 10)"
check "the user's saved languages and model are untouched" "$choices_before" "$(user_choices)"
