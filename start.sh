#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

CHROME_USER_DATA_DIR="$HOME/.config/google-chrome"
CHROME_BIN_PATTERN="/opt/google/chrome/chrome"

if pgrep -f "$CHROME_BIN_PATTERN" > /dev/null 2>&1; then
  echo "[start.sh] Your real Chrome browser is currently running."
  echo "[start.sh] This bot reuses your actual Chrome profile (so it has your saved logins for"
  echo "[start.sh] Naukri/LinkedIn/Indeed etc.), and Chrome will not let a second instance open"
  echo "[start.sh] on the same profile while one is already running."
  read -r -p "[start.sh] Close all open Chrome windows now and continue? Unsaved Chrome tabs/work will be lost. [y/N] " answer
  case "$answer" in
    [yY][eE][sS]|[yY])
      echo "[start.sh] Closing Chrome..."
      pkill -15 -f "$CHROME_BIN_PATTERN" 2>/dev/null || true
      sleep 2
      pkill -9 -f "$CHROME_BIN_PATTERN" 2>/dev/null || true
      sleep 1
      ;;
    *)
      echo "[start.sh] Aborting. Close Chrome yourself and re-run, or re-run and answer 'y'."
      exit 1
      ;;
  esac
fi

echo "[start.sh] Clearing stale Chrome profile lock files..."
rm -f "$CHROME_USER_DATA_DIR"/SingletonLock "$CHROME_USER_DATA_DIR"/SingletonCookie "$CHROME_USER_DATA_DIR"/SingletonSocket 2>/dev/null || true

if [ ! -f "resume.pdf" ]; then
  echo "[start.sh] ERROR: resume.pdf not found in $(pwd). Place your resume there before running." >&2
  exit 1
fi

if [ ! -f "config.json" ]; then
  echo "[start.sh] ERROR: config.json not found. Copy config.example.json to config.json and edit it first." >&2
  exit 1
fi

if [ ! -f ".env" ]; then
  echo "[start.sh] WARNING: .env not found. Gemini AI features will be disabled; the bot will fall back to local (non-AI) logic."
fi

if [ ! -d "node_modules" ]; then
  echo "[start.sh] Installing dependencies..."
  npm install
fi

echo "[start.sh] Starting Job Application Bot..."
node src/index.js
