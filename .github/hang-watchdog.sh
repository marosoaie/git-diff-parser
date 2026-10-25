#!/usr/bin/env bash
# TEMPORARY diagnostic for PR #5's CI hang; reverted before the fix.
# Runs the suite in the foreground (same stdin/stdout as the step); after
# $1 seconds a watchdog prints, straight to the step log, the unfinished
# tests, every process on the machine, and the stacks and open files of
# every process under the step, then kills the step.
set -u
limit=${1:-180}
out=${RUNNER_TEMP:-/tmp}/hang
mkdir -p "$out"
top=$$
os=$(uname)

# Prints the pids under $1, skipping the subtree rooted at $2.
descendants() {
  local kid
  for kid in $(ps -A -o pid= -o ppid= | awk -v p="$1" '$2 == p { print $1 }'); do
    [ "$kid" = "$2" ] && continue
    echo "$kid"
    descendants "$kid" "$2"
  done
}

# Runs "$@" for at most $1 seconds, so a stuck debugger can't eat the job.
with_limit() {
  local s=$1 p k
  shift
  "$@" &
  p=$!
  ( sleep "$s"; kill -9 "$p" 2>/dev/null ) &
  k=$!
  wait "$p"
  kill "$k" 2>/dev/null
}

unfinished() {
  # Glyph-agnostic: macOS terminals print SF Symbols instead of ◇ ✔ ✘.
  grep -oE 'Test "[^"]*" started' "$out/test.log" | sed -E 's/Test "(.*)" started/\1/' | sort -u > "$out/started.txt"
  grep -oE 'Test "[^"]*" (with [0-9]+ test cases? )?(passed|failed)' "$out/test.log" \
    | sed -E 's/Test "(.*)" (with .*|passed|failed).*/\1/' | sort -u > "$out/finished.txt"
  comm -23 "$out/started.txt" "$out/finished.txt"
}

dump() {
  # Not $BASHPID: macOS's /bin/bash 3.2 lacks it.
  local self pids p
  self=$(cat "$out/watchdog.pid")
  echo "::error::HANG: the suite is still running after ${limit} s"
  pids=$(descendants "$top" "$self")
  echo "##### UNFINISHED TESTS"
  unfinished
  echo "##### ALL PROCESSES"
  if [ "$os" = Darwin ]; then
    ps -A -o pid,ppid,pgid,stat,etime,command | cut -c1-250
  else
    ps -eo pid,ppid,pgid,stat,etimes,wchan:32,args | cut -c1-250
  fi
  for p in $pids; do
    echo
    echo "##### PID $p: $(ps -o command= -p "$p" | cut -c1-250)"
    if [ "$os" = Darwin ]; then
      lsof -n -P -p "$p" 2>/dev/null | grep -vE " (REG|DIR) " | cut -c1-200
      with_limit 45 sudo lldb --batch -p "$p" -o "thread backtrace all" -o "detach" > "$out/lldb-$p.txt" 2>&1
    else
      for t in /proc/"$p"/task/*; do
        echo "tid ${t##*/} wchan=$(cat "$t/wchan" 2>/dev/null) syscall=$(cut -d' ' -f1 "$t/syscall" 2>/dev/null)"
      done
      ls -l /proc/"$p"/fd 2>/dev/null | grep -v " /" | cut -c40-200
      with_limit 45 lldb --batch -p "$p" -o "thread backtrace all" -o "detach" > "$out/lldb-$p.txt" 2>&1
    fi
    head -3000 "$out/lldb-$p.txt"
  done
  if [ "$os" != Darwin ]; then
    echo "##### EVERY PROCESS HOLDING A PIPE"
    for d in /proc/[0-9]*; do
      ls -l "$d"/fd 2>/dev/null | grep -o "pipe:\[[0-9]*\]" | sort -u | sed "s|^|${d#/proc/} |"
    done
  fi
  echo "##### END OF DUMP"
  for p in $pids; do kill -9 "$p" 2>/dev/null; done
  kill -9 "$top"
}

( sleep "$limit"; dump ) &
echo "$!" > "$out/watchdog.pid"

swift test --skip-build 2>&1 | tee "$out/test.log"
status=${PIPESTATUS[0]}
kill "$(cat "$out/watchdog.pid")" 2>/dev/null
exit "$status"
