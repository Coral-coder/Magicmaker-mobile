#!/usr/bin/env bash
# Create GitHub repo and push this monorepo (requires: gh auth login)
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="${1:-Coral-coder/Magicmaker-mobile}"

if ! gh auth status &>/dev/null; then
  echo "Run: gh auth login"
  exit 1
fi

git config http.postBuffer 524288000

if git remote get-url origin &>/dev/null; then
  git remote set-url origin "https://github.com/${REPO}.git"
else
  git remote add origin "https://github.com/${REPO}.git"
fi

if gh repo view "$REPO" &>/dev/null; then
  echo "Repo exists — pushing…"
  git push -u origin main
else
  echo "Creating ${REPO}…"
  gh repo create "$REPO" --public --source=. --remote=origin --push \
    --description "MagicMaker iOS + Android — Disney BLE scan, transmit, Starlight wand, iPhone relay"
fi

echo "Done: https://github.com/${REPO}"
