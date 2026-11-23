#!/bin/bash
# Takes a 6-second performance sample of the running LoopNest and saves it next to this file.
cd "$(dirname "$0")"
PID=$(pgrep -x LoopNest | head -1)
if [ -z "$PID" ]; then echo "LoopNest is not running." > profile.txt; exit 0; fi
{ echo "== top =="; top -l 2 -pid "$PID" -stats pid,cpu,threads,mem | tail -3; echo; echo "== threads =="; top -l 1 -pid "$PID" -H 2>/dev/null | head -0; } > profile.txt
sample "$PID" 6 -mayDie >> profile.txt 2>&1
echo done >> profile.txt
