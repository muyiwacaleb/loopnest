#!/bin/bash
# Double-click to put this project on GitHub. It creates a repository under YOUR account and pushes everything.
# Needs git (comes with Apple's Command Line Tools) and the GitHub command-line tool: https://cli.github.com
cd "$(dirname "$0")" || exit 1
NAME="${1:-loopnest}"
if ! command -v git >/dev/null; then echo "git is missing. Run: xcode-select --install"; read -n 1 -s -r -p "Press any key..."; exit 1; fi
if ! command -v gh >/dev/null && command -v brew >/dev/null; then
  echo "Installing the GitHub command-line tool with Homebrew..."
  brew install gh
fi
if ! command -v gh >/dev/null; then
  echo "The GitHub command-line tool (gh) is not installed."
  echo "Easy way: install it from https://cli.github.com, run 'gh auth login' once, then double-click this file again."
  echo "Manual way: create an empty repository on github.com, then in this folder run:"
  echo "  git init -b main && git add -A && git commit -m 'Initial commit' && git remote add origin <your repo URL> && git push -u origin main"
  read -n 1 -s -r -p "Press any key..."; exit 1
fi
gh auth status >/dev/null 2>&1 || gh auth login
read -p "Make the repository public or private? [public/private] " VIS
[ "$VIS" = "private" ] || VIS=public
[ -d .git ] || git init -b main
git add -A
git commit -m "LoopNest: virtual audio devices, per-app mixer and broadcast tools for macOS" || true
gh repo create "$NAME" "--$VIS" --source . --remote origin --push
echo "Done."
read -n 1 -s -r -p "Press any key to close..."
