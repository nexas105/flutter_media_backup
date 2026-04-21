#!/bin/sh
# Runs `flutter run` with --dart-define args derived from a .env file.
# Avoids Make's $(shell) word-splitting which mangles values containing spaces.
#
# Usage: flutter_run.sh <example_dir> <env_file> <device_id>

set -e

EXAMPLE_DIR="$1"; shift || exit 1
ENV_FILE="$1"; shift || exit 1
DEVICE_ID="$1"; shift || exit 1

cd "$EXAMPLE_DIR"

# Fall back to a sibling .env one level up if the requested one doesn't exist.
if [ ! -f "$ENV_FILE" ]; then
  ALT="$(dirname "$ENV_FILE")/../.env"
  if [ -f "$ALT" ]; then
    ENV_FILE="$ALT"
  fi
fi

# Build positional args. Each --dart-define stays one shell word even when the
# value contains spaces because we pass the whole thing as a single positional.
set --
if [ -f "$ENV_FILE" ]; then
  echo "  using $ENV_FILE"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|\#*) continue ;;
    esac

    key=${line%%=*}
    val=${line#*=}

    key=$(printf '%s' "$key" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    case "$key" in
      *[!A-Za-z0-9_]*|'') continue ;;
    esac

    val=$(printf '%s' "$val" | sed 's/[[:space:]]*$//')
    case "$val" in
      \"*\") val=${val#\"}; val=${val%\"} ;;
      \'*\') val=${val#\'}; val=${val%\'} ;;
    esac

    set -- "$@" "--dart-define=${key}=${val}"
  done < "$ENV_FILE"
else
  echo "  (no .env at $ENV_FILE — using defaults)"
fi

exec flutter run -d "$DEVICE_ID" "$@"
