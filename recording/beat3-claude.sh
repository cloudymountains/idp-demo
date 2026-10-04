#!/usr/bin/env bash
# Beat 3 in Claude Code: the same skill, the same steering files, a terminal.
#
# The portability claim, demonstrated. Nothing here is Claude-specific except
# the binary name: the skill is the file Kiro reads, reached through a symlink.
#
#   asciinema rec recording/beat3-claude.cast --window-size 150x46 \
#     --command ./recording/beat3-claude.sh --overwrite
set -u
cd "$(dirname "$0")/.."

# asciinema --command runs with no TERM, and `clear` then warns about it on
# the first line of the recording. ANSI works regardless of terminfo.
export TERM="${TERM:-xterm-256color}"
wipe() { printf '\033[2J\033[H'; }

beat()  { printf '\n\033[1;35m%s\033[0m\n\n' "$1"; sleep 3; }
quiet() { printf '\033[2m%s\033[0m\n' "$1"; sleep 2; }
typed() { printf '\033[2m$ \033[0m'; printf '%s' "$1" | while IFS= read -r -n1 c; do printf '%s' "$c"; sleep 0.035; done; printf '\n\n'; sleep 1; }

wipe
beat "Same repository. Same skill. Different agent."
quiet "$ ls -l .claude/skills/provision-service"
ls -l .claude/skills/provision-service | sed 's/^/    /'
printf '\n    \033[1mOne SKILL.md. A symlink, not a copy, and not a translation.\033[0m\n'
sleep 4

beat "Claude reads the steering files because CLAUDE.md points at them."
quiet "$ grep -A5 'Team knowledge' CLAUDE.md"
grep -A6 "## Team knowledge" CLAUDE.md | tail -5 | sed 's/^/    /'
sleep 4

beat "One sentence. Every tool call it makes is shown."
typed 'claude -p "I need a small postgres database for the analytics service in dev, owner data-team"'

claude -p "I need a small postgres database for the analytics service in dev, owner data-team" \
  --output-format stream-json --verbose --permission-mode acceptEdits \
  --allowed-tools "Read,Write,Edit,Bash,Glob,Grep,Skill" 2>/dev/null \
  | ./.venv/bin/python recording/streamfmt.py
sleep 3

beat "What it wrote:"
quiet "$ cat services/analytics/service.yaml"
if [ -f services/analytics/service.yaml ]; then
  cat services/analytics/service.yaml | sed 's/^/    /'
else
  printf '    \033[1;31mno manifest produced\033[0m\n'
fi
sleep 5

beat "Two agents, two manifests, one schema. Compare them."
quiet "$ diff <(kiro) <(claude)   # billing vs analytics, ignoring names"
diff <(sed -E 's/billing|analytics/SERVICE/; s/payments-team|data-team/TEAM/; s/CC-[0-9]+/CC/' services/billing/service.yaml 2>/dev/null) \
     <(sed -E 's/billing|analytics/SERVICE/; s/payments-team|data-team/TEAM/; s/CC-[0-9]+/CC/' services/analytics/service.yaml 2>/dev/null) \
  && printf '    \033[1;32midentical shape.\033[0m The golden path was written once.\n' \
  || printf '    \033[2m(differences above are optional fields, both valid)\033[0m\n'
sleep 5

printf '\n\033[1;36m    Write the golden path once. Let people keep the tool they like.\033[0m\n\n'
sleep 4
