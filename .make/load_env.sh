#!/bin/sh
# Reads KEY=VALUE pairs from $1 and prints them as
# "--dart-define=KEY=VALUE " for inclusion in a `flutter run` command line.
# Skips blank lines and lines starting with `#`. Strips surrounding quotes.

ENV_FILE="$1"
[ -n "$ENV_FILE" ] || exit 0
# Also accept a sibling .env at the plugin root (one level up from example/)
if [ ! -f "$ENV_FILE" ]; then
  ALT="$(dirname "$ENV_FILE")/../.env"
  if [ -f "$ALT" ]; then
    ENV_FILE="$ALT"
  else
    exit 0
  fi
fi

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    ''|\#*) continue ;;
  esac

  key=${line%%=*}
  val=${line#*=}

  # Trim surrounding whitespace from key.
  key=$(printf '%s' "$key" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  case "$key" in
    *[!A-Za-z0-9_]*|'') continue ;;
  esac

  # Trim trailing whitespace + surrounding quotes from val.
  val=$(printf '%s' "$val" | sed 's/[[:space:]]*$//')
  case "$val" in
    \"*\") val=${val#\"}; val=${val%\"} ;;
    \'*\') val=${val#\'}; val=${val%\'} ;;
  esac

  printf -- '--dart-define=%s=%s ' "$key" "$val"
done < "$ENV_FILE"
