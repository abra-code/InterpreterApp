#!/bin/sh
# helpers/fake_record.sh - argv recording, shared by every fake.
#
# Sourced, not executed, as the first thing each fake does. It records the
# invocation and leaves $fake_dir and $fake_name set for whatever follows.
#
# Two records, because neither alone is both readable and exact:
#
#   <name>.log        one line per invocation, arguments joined by tabs. For
#                     reading and for grep. LOSSY: an argument containing a tab
#                     or a newline is indistinguishable from two arguments.
#   <name>.argv.<n>   one file per invocation, one argument per line, in order.
#                     Exact, and the record to assert against when the argument
#                     text is what is under test.
#   <name>.count      how many times the tool was called - its own file rather
#                     than a line count of the log, so a call whose arguments
#                     contain a newline still counts as one call.

fake_name="$(/usr/bin/basename "$0")"
fake_dir="${INTERP_FAKE_DIR:?fake tool invoked with no INTERP_FAKE_DIR}"
/bin/mkdir -p "$fake_dir"

{
    fake_first=1
    for fake_arg in "$@"; do
        if [ "$fake_first" = "1" ]; then
            printf '%s' "$fake_arg"
            fake_first=0
        else
            printf '\t%s' "$fake_arg"
        fi
    done
    printf '\n'
} >> "$fake_dir/$fake_name.log"

fake_n=$(( $(/bin/cat "$fake_dir/$fake_name.count" 2>/dev/null || echo 0) + 1 ))
printf '%s' "$fake_n" > "$fake_dir/$fake_name.count"

: > "$fake_dir/$fake_name.argv.$fake_n"
for fake_arg in "$@"; do
    printf '%s\n' "$fake_arg" >> "$fake_dir/$fake_name.argv.$fake_n"
done
unset fake_first fake_arg

fake_emit() { # <file>
    [ -f "$1" ] && /bin/cat "$1"
    return 0
}

fake_rc() { # <file> <default>
    if [ -f "$1" ]; then
        /bin/cat "$1"
    else
        printf '%s' "$2"
    fi
}
