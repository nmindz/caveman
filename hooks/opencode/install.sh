#!/usr/bin/env bash
#
# Caveman installer for OpenCode CLI.
#
# Idempotent. Reads the live source-of-truth files from this repo:
#   plugins/caveman/opencode/caveman.ts  -> $CONFIG/plugin/caveman.ts
#   skills/caveman/SKILL.md              -> $CONFIG/skill/caveman/SKILL.md
#   rules/caveman-activate.md            -> $CONFIG/AGENTS.md (between markers)
#
# $CONFIG defaults to $OPENCODE_CONFIG_DIR or ~/.config/opencode.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CONFIG_DIR="${OPENCODE_CONFIG_DIR:-$HOME/.config/opencode}"

if [ -d "$CONFIG_DIR/plugins" ] && [ ! -d "$CONFIG_DIR/plugin" ]; then
  PLUGIN_DIR="$CONFIG_DIR/plugins"
else
  PLUGIN_DIR="$CONFIG_DIR/plugin"
fi

SKILL_DIR="$CONFIG_DIR/skill/caveman"
COMMANDS_DIR="$CONFIG_DIR/commands"
AGENTS_MD="$CONFIG_DIR/AGENTS.md"

PLUGIN_SRC="$REPO_ROOT/plugins/caveman/opencode/caveman.ts"
SKILL_SRC="$REPO_ROOT/skills/caveman/SKILL.md"
RULES_SRC="$REPO_ROOT/rules/caveman-activate.md"
COMMANDS_SRC_DIR="$REPO_ROOT/plugins/caveman/opencode/commands"

BEGIN_MARK="<!-- BEGIN CAVEMAN -->"
END_MARK="<!-- END CAVEMAN -->"

for src in "$PLUGIN_SRC" "$SKILL_SRC" "$RULES_SRC"; do
  if [ ! -f "$src" ]; then
    echo "error: source missing: $src" >&2
    exit 1
  fi
done

if [ ! -d "$COMMANDS_SRC_DIR" ]; then
  echo "error: commands source dir missing: $COMMANDS_SRC_DIR" >&2
  exit 1
fi

mkdir -p "$CONFIG_DIR" "$PLUGIN_DIR" "$SKILL_DIR" "$COMMANDS_DIR"

cp "$PLUGIN_SRC" "$PLUGIN_DIR/caveman.ts"
cp "$SKILL_SRC" "$SKILL_DIR/SKILL.md"

# Install slash commands. Each .md becomes /<basename> in OpenCode autocomplete.
for cmd in "$COMMANDS_SRC_DIR"/*.md; do
  [ -f "$cmd" ] || continue
  cp "$cmd" "$COMMANDS_DIR/$(basename "$cmd")"
done

RULES_CONTENT="$(cat "$RULES_SRC")"
BLOCK="${BEGIN_MARK}
${RULES_CONTENT}
${END_MARK}"

touch "$AGENTS_MD"

if grep -qF "$BEGIN_MARK" "$AGENTS_MD"; then
  TMP="$(mktemp)"
  awk \
    -v begin="$BEGIN_MARK" \
    -v end="$END_MARK" \
    -v block="$BLOCK" '
      BEGIN { skip = 0 }
      {
        if ($0 == begin) { print block; skip = 1; next }
        if ($0 == end && skip == 1) { skip = 0; next }
        if (skip == 0) { print }
      }
    ' "$AGENTS_MD" > "$TMP"
  mv "$TMP" "$AGENTS_MD"
else
  if [ -s "$AGENTS_MD" ]; then
    printf '\n%s\n' "$BLOCK" >> "$AGENTS_MD"
  else
    printf '%s\n' "$BLOCK" > "$AGENTS_MD"
  fi
fi

cat <<EOF
caveman installed for OpenCode.
  plugin   -> $PLUGIN_DIR/caveman.ts
  skill    -> $SKILL_DIR/SKILL.md
  commands -> $COMMANDS_DIR/caveman*.md
  rules    -> $AGENTS_MD (between $BEGIN_MARK / $END_MARK)

Plugin auto-loads from \`$PLUGIN_DIR/\`. No config edit needed.

If you prefer explicit registration, add this line to your opencode.jsonc:

  "plugin": ["file://$PLUGIN_DIR/caveman.ts"]

Restart OpenCode. Then test:
  - Type /caveman in autocomplete (file-based slash command)
  - Or send "talk like caveman"
  - Or set CAVEMAN_DEFAULT_MODE=ultra to auto-activate at session start
EOF
