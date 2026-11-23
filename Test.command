#!/bin/bash
# Runs LoopNest's built-in self-test and saves the result to test-results.txt
cd "$(dirname "$0")"
if [ ! -x build/LoopNest.app/Contents/MacOS/LoopNest ]; then echo "Build LoopNest first (Build.command)."; read -n 1 -s -r -p "Press any key..."; exit 1; fi
build/LoopNest.app/Contents/MacOS/LoopNest --selftest 2>&1 | tee test-results.txt
echo ""
read -n 1 -s -r -p "Press any key to close..."
