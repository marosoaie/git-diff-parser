#!/usr/bin/env bash
# TEMPORARY diagnostic for PR #5's CI hang; reverted before the fix.
# Runs the suite in the foreground (same stdin/stdout as the step); a
# watchdog dumps every thread of every process under it after $1 seconds,
# then kills the run.
set -u
limit=${1:-300}
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

dump() {
  # Not $BASHPID: macOS's /bin/bash 3.2 lacks it.
  local self pids p
  self=$(cat "$out/watchdog.pid")
  echo "::error::HANG: the suite is still running after ${limit} s"
  pids=$(descendants "$top" "$self")
  if [ "$os" = Darwin ]; then
    ps -A -o pid,ppid,stat,etime,command > "$out/ps.txt"
  else
    ps -eo pid,ppid,stat,etimes,wchan:32,args > "$out/ps.txt"
  fi
  {
    echo "### processes under the step"
    for p in $pids; do ps -o pid=,ppid=,stat=,command= -p "$p"; done
    for p in $pids; do
      echo
      echo "################ pid $p: $(ps -o command= -p "$p" | cut -c1-300)"
      if [ "$os" = Darwin ]; then
        with_limit 90 sudo lldb --batch -p "$p" -o "thread backtrace all" -o "detach" > "$out/lldb-$p.txt" 2>&1
        head -4000 "$out/lldb-$p.txt"
        with_limit 90 sudo spindump "$p" 2 50 -file "$out/spindump-$p.txt" > /dev/null 2>&1
        echo "---- spindump $p"
        head -3000 "$out/spindump-$p.txt" 2>/dev/null
      else
        for t in /proc/"$p"/task/*; do
          echo "tid ${t##*/} wchan=$(cat "$t/wchan" 2>/dev/null) syscall=$(cut -d' ' -f1 "$t/syscall" 2>/dev/null)"
        done
        with_limit 90 lldb --batch -p "$p" -o "thread backtrace all" -o "detach" > "$out/lldb-$p.txt" 2>&1
        head -4000 "$out/lldb-$p.txt"
        ls -l /proc/"$p"/fd 2>/dev/null | cut -c1-200
      fi
    done
  } > "$out/stacks.txt" 2>&1
  for p in $pids; do kill -9 "$p" 2>/dev/null; done
}

( sleep "$limit"; dump ) &
watchdog=$!
echo "$watchdog" > "$out/watchdog.pid"

swift test --skip-build 2>&1 | tee "$out/test.log"
status=${PIPESTATUS[0]}
kill "$watchdog" 2>/dev/null

if [ -s "$out/stacks.txt" ]; then
  # Tests that started and never finished.
  # Glyph-agnostic: macOS terminals print SF Symbols instead of ◇ ✔ ✘.
  grep -oE 'Test "[^"]*" started' "$out/test.log" | sed -E 's/Test "(.*)" started/\1/' | sort -u > "$out/started.txt"
  grep -oE 'Test "[^"]*" (with [0-9]+ test cases? )?(passed|failed)' "$out/test.log" \
    | sed -E 's/Test "(.*)" (with .*|passed|failed).*/\1/' | sort -u > "$out/finished.txt"
  echo "### UNFINISHED TESTS"
  comm -23 "$out/started.txt" "$out/finished.txt"
  echo "### STACKS"
  cat "$out/stacks.txt"
  exit 1
fi
exit "$status"
