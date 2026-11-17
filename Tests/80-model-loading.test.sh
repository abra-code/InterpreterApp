#!/bin/sh
# Tests/80-model-loading.test.sh - the model loading manager (lib.interp.load.sh): one job at a
# time across the app, and a memory budget for what is loaded.
#
# The queue and the budget are library functions, called here directly. The poller's half - when
# it hands a queued job to the broker, and the window states it shows meanwhile - runs inside the
# poll loop and is not covered (the suite's note in lib.test.interp.sh says why). What a handler
# decides is covered: whether it asks, what it queues, what Stop withdraws.
. "${OMCTEST_LIB:?set OMCTEST_LIB, or run via: appletbuilder test}"
. "$OMCTEST_TESTS/lib.test.interp.sh"

# Another window, with a poller that runs (the suite runner's own pid, alive all run).
other_spool() { printf '%s/%s' "$(sessions_dir)" "$1"; }
make_other_window() { # <uuid> -> prints the spool
    local s="$(other_spool "$1")"
    /bin/mkdir -p "$s"
    printf '%s' "$OMC_APP_PROCESS_ID" > "$s/poll.pid"
    printf '%s' "$s"
}
# A pid that is certainly not running: a process minted and waited for.
dead_pid() {
    /bin/sh -c ':' &
    local p=$!
    wait "$p"
    printf '%s' "$p"
}
queue_count() { interp_call queue_entries | /usr/bin/grep -c .; }
own_entry() { spool_file queue.entry; }

# A window with a model selected and From/To set, ready for interp.translate.
open_translator() {
    make_mlx_model "translategemma-12b-4bit" >/dev/null
    omc_control_defaults interpreter.window
    omc_run interp.window.init
    printf '%s' "$(models_dir)/translategemma-12b-4bit" > "$(spool_dir)/model.dir"
    printf '%s' "$OMC_APP_PROCESS_ID" > "$(spool_dir)/poll.pid"
    omc_control "$FROM_PICKER" "$(interp_call from_code_index "$(spool_dir)" en)"
    omc_control "$TO_PICKER" "$(interp_call lang_code_index "$(spool_dir)" de)"
    omc_control "$SRC_EDITOR" "The quick brown fox."
}

section "the queue keeps arrival order and names its head"
reset_document
a="$(make_other_window window-a)"
b="$(make_other_window window-b)"
interp_call queue_enqueue "$a" "Translation with A"
interp_call queue_enqueue "$b" "Humanize with B"
check "two entries" "2" "$(queue_count)"
check "the first to arrive is first" "$(/bin/cat "$a/queue.entry")" "$(interp_call queue_entries | /usr/bin/head -1)"
check "it is the head" "yes" "$(interp_is queue_is_head "$a")"
check "the second is not" "no" "$(interp_is queue_is_head "$b")"
check "the second waits for the first" "$(/bin/cat "$a/queue.entry")" "$(interp_call queue_ahead_of "$b")"
check "and the entry carries its label" "Translation with A" \
    "$(interp_call queue_entry_label "$(/bin/cat "$a/queue.entry")")"
# Entry names must sort as they arrived: fixed-width microseconds.
check "the stamp is fixed-width" "16" "$(interp_call queue_stamp | /usr/bin/tr -d '\n' | /usr/bin/wc -c | /usr/bin/tr -d ' ')"

section "a released entry lets the next window go"
a_entry="$(/bin/cat "$a/queue.entry")"
interp_call queue_release "$a"
check_absent "the entry is gone" "$a_entry"
check "and the claim with it" "" "$(/bin/cat "$a/queue.entry" 2>/dev/null)"
check "the second is the head now" "yes" "$(interp_is queue_is_head "$b")"

section "re-queuing replaces a window's old entry"
interp_call queue_enqueue "$b" "Humanize with B"
check "still one entry for that window" "1" "$(queue_count)"

section "an entry whose window is gone, or whose poller died, does not block the queue"
reset_document
a="$(make_other_window window-a)"
b="$(make_other_window window-b)"
interp_call queue_enqueue "$a" "Translation with A"
interp_call queue_enqueue "$b" "Translation with B"
a_entry="$(/bin/cat "$a/queue.entry")"
printf '%s' "$(dead_pid)" > "$a/poll.pid"
check "a crashed poller's entry is not live" "1" "$(queue_count)"
check_absent "and it was removed on the way" "$a_entry"
check "the next window is the head" "yes" "$(interp_is queue_is_head "$b")"
b_entry="$(/bin/cat "$b/queue.entry")"
/bin/rm -rf "$b"
check "a closed window's entry is not live" "0" "$(queue_count)"
check_absent "and it was removed too" "$b_entry"

section "an entry its window no longer claims is not live"
reset_document
a="$(make_other_window window-a)"
interp_call queue_enqueue "$a" "Translation with A"
printf '%s' "something-else" > "$a/queue.entry"
check "an unclaimed entry does not count" "0" "$(queue_count)"

section "the budget is 75% of RAM, and an engine holds its weights plus 15% and 768 MiB"
reset_document
machine_ram_gb 32
check "32 GB of RAM gives 24 GB" "24576" "$(interp_call memory_budget_mib)"
check "a 10 GiB model is held as 12.25 GiB" "12544" "$(interp_call engine_footprint_mib 10737418240)"
check "an unreadable size counts as nothing" "0" "$(interp_call engine_footprint_mib '')"
fake_answer sysctl 1 ""
check "RAM that cannot be read gives no budget" "" "$(interp_call memory_budget_mib)"

section "other apps' engines are summed from the scan"
reset_document
printf '%s\n' "4242 30000 gemma-4-31B-it-Q4_K_M.gguf" "4243 1000 small-model" > "$INTERP_FOREIGN_ENGINES_FILE"
check "both are counted" "31000" "$(interp_eval 'foreign_engines | sum_mib')"
: > "$INTERP_FOREIGN_ENGINES_FILE"
check "none means nothing" "0" "$(interp_eval 'foreign_engines | sum_mib')"

section "making room unloads other windows' models, least recently used first, only as needed"
reset_document
# 2 GiB of RAM: a 1536 MiB budget. A fixture model is a few KiB on disk, so each engine is held
# as 768 MiB: this window's plus one other fits exactly, a third does not.
machine_ram_gb 2
m="$(make_mlx_model "translategemma-12b-4bit")"
/bin/sleep 60 & live1=$!
/bin/sleep 60 & live2=$!
/bin/sleep 60 & live3=$!
for w in old mid new; do
    s="$(make_other_window "window-$w")"
    printf '%s' "$m" > "$s/broker.model"
    printf '{"state":"ready"}' > "$s/status.json"
done
printf '%s' "$live1" > "$(other_spool window-old)/broker.pid"
printf '%s' "$live2" > "$(other_spool window-mid)/broker.pid"
printf '%s' "$live3" > "$(other_spool window-new)/broker.pid"
/usr/bin/touch -t 202601010101 "$(other_spool window-old)/status.json"
/usr/bin/touch -t 202601010202 "$(other_spool window-mid)/status.json"
/usr/bin/touch -t 202601010303 "$(other_spool window-new)/status.json"
/bin/mkdir -p "$(spool_dir)"
check "the other windows' engines are listed oldest first" \
    "$(other_spool window-old) $(other_spool window-mid) $(other_spool window-new)" \
    "$(interp_call own_engines_except "$(spool_dir)" | /usr/bin/awk '{ $1 = ""; $2 = ""; sub(/^ +/, ""); print }' | /usr/bin/paste -s -d ' ' -)"
evicted="$OMCTEST_WORK/evicted.log"
: > "$evicted"
# evict_engine kills processes it verifies by argv, which the fixtures cannot imitate; the choice
# of WHICH windows to unload is what is under test here.
interp_eval "evict_engine() { printf '%s\n' \"\$1\" >> '$evicted'; }; make_room_for '$(spool_dir)' '$m'"
check "the two least recently used were unloaded" \
    "$(other_spool window-old) $(other_spool window-mid)" "$(/usr/bin/paste -s -d ' ' "$evicted")"

section "nothing is unloaded when the model fits"
: > "$evicted"
machine_ram_gb 32
interp_eval "evict_engine() { printf '%s\n' \"\$1\" >> '$evicted'; }; make_room_for '$(spool_dir)' '$m'"
check "no window lost its model" "0" "$(/usr/bin/grep -c . "$evicted")"

section "other apps' engines count against the room, but are never unloaded"
: > "$evicted"
printf '%s\n' "4242 24000 gemma-4-31B" > "$INTERP_FOREIGN_ENGINES_FILE"
interp_eval "evict_engine() { printf '%s\n' \"\$1\" >> '$evicted'; }; make_room_for '$(spool_dir)' '$m'"
check "every Interpreter window is unloaded before the other app counts as the cause" \
    "$(other_spool window-old) $(other_spool window-mid) $(other_spool window-new)" "$(/usr/bin/paste -s -d ' ' "$evicted")"
: > "$INTERP_FOREIGN_ENGINES_FILE"

section "a window's own broker is not one of the others"
printf '%s' "$live1" > "$(spool_dir)/broker.pid"
printf '%s' "$m" > "$(spool_dir)/broker.model"
check "this window is skipped" "3" "$(interp_call own_engines_except "$(spool_dir)" | /usr/bin/grep -c .)"
check "but another window counts it" "yes" \
    "$(interp_call own_engines_except "$(other_spool window-new)" | /usr/bin/grep -q -F "$(spool_dir)" && echo yes || echo no)"
/bin/kill "$live1" "$live2" "$live3" 2>/dev/null

section "an engine that is not running holds nothing"
reset_document
s="$(make_other_window window-stopped)"
printf '%s' "$(make_mlx_model "translategemma-12b-4bit")" > "$s/broker.model"
printf '%s' "$(dead_pid)" > "$s/broker.pid"
check "a dead broker is not listed" "" "$(interp_call own_engines_except "$(spool_dir)")"

section "Translate with nothing else running queues the job without asking"
reset_document
open_translator
omc_run interp.translate
check_status "the handler ran" 0
check "nobody was asked" "0" "$(alerts_count)"
check_exists "the job waits for the poller" "$(spool_dir)/job.next.json"
check_absent "it is not the broker's yet" "$(spool_dir)/job.json"
check "it records the model it was built for" "$(models_dir)/translategemma-12b-4bit" "$(spool_file job.next.model)"
check "the window joined the queue" "yes" "$([ -f "$(own_entry)" ] && echo yes || echo no)"
check "under its model's name" "Translation with TranslateGemma 12B (4-bit)" "$(interp_call queue_entry_label "$(own_entry)")"
check "and it is the head" "yes" "$(interp_is queue_is_head "$(spool_dir)")"
check "the status line says it started" "Translating…" "$(ui_value "$STATUS_TEXT")"

section "Translate while another window works asks before queuing"
reset_document
open_translator
other="$(make_other_window window-busy)"
interp_call queue_enqueue "$other" "Humanize with Humanizer 12B (8-bit)"
alert_answer 0
omc_run interp.translate
check "the user was asked" "1" "$(alerts_count)"
check "about the job that runs" "1" "$(alerts_mention 'Humanize with Humanizer 12B (8-bit)')"
check "offering to queue" "1" "$(alerts_mention 'Queue')"
check_exists "Queue queued it" "$(spool_dir)/job.next.json"
check "behind the other window" "$(/bin/cat "$other/queue.entry")" "$(interp_call queue_ahead_of "$(spool_dir)")"
check "and the status line says it waits" "Waiting for another window to finish…" "$(ui_value "$STATUS_TEXT")"
check "the previous translation was cleared for the new one" "1" "$(ui_calls omc_set_value_from_stdin)"

section "Cancel leaves nothing queued and the window usable"
reset_document
open_translator
other="$(make_other_window window-busy)"
interp_call queue_enqueue "$other" "Translation with TranslateGemma 27B (6-bit)"
alert_answer 1
omc_run interp.translate
check "the user was asked" "1" "$(alerts_count)"
check_absent "nothing was queued" "$(spool_dir)/job.next.json"
check "the window is not in the queue" "" "$(own_entry)"
check "the previous translation was not cleared" "0" "$(ui_calls omc_set_value_from_stdin)"
check "Translate is back on" "1" "$(ui_enabled "$TRANSLATE_BTN")"
check "Stop is off" "0" "$(ui_enabled "$STOP_BTN")"
check "the status line says so" "Cancelled." "$(ui_value "$STATUS_TEXT")"

section "two jobs waiting are counted in the question"
reset_document
open_translator
interp_call queue_enqueue "$(make_other_window window-one)" "Translation with A"
/bin/sleep 0.01
interp_call queue_enqueue "$(make_other_window window-two)" "Translation with B"
alert_answer 0
omc_run interp.translate
check "the first is named" "1" "$(alerts_mention 'busy: Translation with A')"
check "and the rest counted" "1" "$(alerts_mention '1 more waiting')"

section "other apps' models that leave no room are asked about"
reset_document
open_translator
machine_ram_gb 32
printf '%s\n' "4242 30000 gemma-4-31B-it-Q4_K_M.gguf" > "$INTERP_FOREIGN_ENGINES_FILE"
alert_answer 1
omc_run interp.translate
check "the user was asked" "1" "$(alerts_count)"
check "about memory" "1" "$(alerts_mention 'High Memory Usage')"
check "naming the other model" "1" "$(alerts_mention 'gemma-4-31B-it-Q4_K_M.gguf')"
check "offering to load anyway" "1" "$(alerts_mention 'Load Anyway')"
check_absent "Cancel queued nothing" "$(spool_dir)/job.next.json"
alert_answer 0
omc_run interp.translate
check_exists "Load Anyway queued it" "$(spool_dir)/job.next.json"

section "other apps' models that leave room are not asked about"
reset_document
open_translator
machine_ram_gb 32
printf '%s\n' "4242 6000 small-model" > "$INTERP_FOREIGN_ENGINES_FILE"
omc_run interp.translate
check "nobody was asked" "0" "$(alerts_count)"
check_exists "the job was queued" "$(spool_dir)/job.next.json"

section "a model this window already holds needs no room"
reset_document
open_translator
machine_ram_gb 32
printf '%s\n' "4242 30000 gemma-4-31B" > "$INTERP_FOREIGN_ENGINES_FILE"
/bin/sleep 60 & live=$!
printf '%s' "$live" > "$(spool_dir)/broker.pid"
printf '%s' "$(models_dir)/translategemma-12b-4bit" > "$(spool_dir)/broker.model"
omc_run interp.translate
check "nobody was asked" "0" "$(alerts_count)"
/bin/kill "$live" 2>/dev/null
: > "$INTERP_FOREIGN_ENGINES_FILE"

section "Stop withdraws a job that is still waiting"
reset_document
open_translator
interp_call queue_enqueue "$(make_other_window window-busy)" "Translation with A"
alert_answer 0
omc_run interp.translate
omc_run interp.stop
check_absent "the waiting job is gone" "$(spool_dir)/job.next.json"
check "the window left the queue" "" "$(own_entry)"
check "the other window is still queued" "1" "$(queue_count)"
check_absent "the broker was not told to stop anything" "$(spool_dir)/stop"
check "the window says so while idle" "Cancelled." "$(spool_file job.notice)"
check "Translate is back on" "1" "$(ui_enabled "$TRANSLATE_BTN")"
check "the status line says so" "Cancelled." "$(ui_value "$STATUS_TEXT")"

section "Stop with no waiting job stops the running one as before"
reset_document
open_translator
printf '{"epoch":1}' > "$(spool_dir)/job.json"
omc_run interp.stop
check_exists "the broker's stop flag was raised" "$(spool_dir)/stop"

section "the next Translate clears an old notice"
reset_document
open_translator
printf '%s' "Cancelled." > "$(spool_dir)/job.notice"
omc_run interp.translate
check_absent "the notice is gone" "$(spool_dir)/job.notice"

omctest_end
