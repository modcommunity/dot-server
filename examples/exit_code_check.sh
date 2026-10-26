#!/usr/bin/env bash
#
# The process exit status survives teardown while the stdin reader is blocked in a read:
# dot-cloud's auto-update quits with 75 and a supervisor restarts on exactly that.
#
#   examples/exit_code_check.sh     exit 0 when both runs end 75, 1 otherwise
#
# Arm it by making _start_tap return false: the reader thread then keeps the process from
# exiting and both runs end 124 (timeout). Runs under `heavy -- ` like any Godot run.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
G=(godot --headless --path . res://examples/exit_code_probe.tscn)
fails=0
check() { # name, status
    if [ "$2" = 75 ]; then echo "  ok   $1: exit 75"; else echo "  FAIL $1: exit $2 (want 75)"; fails=$((fails + 1)); fi
}

# A pipe whose writer stays open for the whole run, as a panel's attached stdin does.
sleep 25 | timeout 20 "${G[@]}" >/dev/null 2>&1
check "open pipe" "${PIPESTATUS[1]}"

# A pty, fed by an open writer too.
sleep 25 | timeout 30 script -qec "timeout 20 ${G[*]}" /dev/null >/dev/null 2>&1
check "pty" "${PIPESTATUS[1]}"

# A typed line still reaches the console through the helper.
out=$( (echo status; sleep 25) | timeout 20 "${G[@]}" 2>&1)
if grep -q "^hostname:" <<<"$out"; then echo "  ok   typed 'status' answered"; else echo "  FAIL typed 'status' got no answer"; fails=$((fails + 1)); fi

# Helper cannot start (DOT_STDIN_NO_HELPER): a pipe's input is off, no blocking thread, still 75.
err=$(mktemp)
sleep 25 | DOT_STDIN_NO_HELPER=1 timeout 20 "${G[@]}" >"$err" 2>&1
check "no helper, open pipe" "${PIPESTATUS[1]}"
if grep -q "Thread object is being destroyed" "$err"; then echo "  FAIL no helper: thread warning"; fails=$((fails + 1)); else echo "  ok   no helper: no thread warning"; fi
if grep -q "stdin helper process could not start" "$err"; then echo "  ok   no helper: WARN logged"; else echo "  FAIL no helper: no WARN"; fails=$((fails + 1)); fi
rm -f "$err"

echo "exit_code_check: $fails failed"
exit $(( fails > 0 ))
