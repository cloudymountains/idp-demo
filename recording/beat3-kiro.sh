#!/usr/bin/env bash
# Beat 3 in Kiro CLI: one sentence becomes a validated manifest.
#
# Paced for a stage and deliberately unfiltered. The agent's tool calls and
# reasoning stream as they happen, because that is the interesting part: you
# can watch it read the schema, read the steering files, and find the cost
# centre on its own. A summarised transcript hides exactly what proves the
# platform is doing the work.
#
#   kiro-cli user login --license free      # once
#   asciinema rec recording/beat3-kiro.cast --window-size 150x46 \
#     --command ./recording/beat3-kiro.sh --overwrite
set -u
cd "$(dirname "$0")/.."

# asciinema --command runs with no TERM, and `clear` then warns about it on
# the first line of the recording. ANSI works regardless of terminfo.
export TERM="${TERM:-xterm-256color}"
wipe() { printf '\033[2J\033[H'; }
export PATH="/Applications/Kiro CLI.app/Contents/MacOS:$PATH"

if ! kiro-cli user whoami >/dev/null 2>&1; then
  printf '\033[1;31mKiro CLI is not logged in.\033[0m  Run: kiro-cli user login --license free\n'
  exit 1
fi

# Start clean, so the agent creates the manifest rather than finding one.
rm -rf services/orders

beat()  { printf '\n\033[1;35m%s\033[0m\n\n' "$1"; sleep 3; }
quiet() { printf '\033[2m%s\033[0m\n' "$1"; sleep 2; }
typed() { printf '\033[2m$ \033[0m'; printf '%s' "$1" | while IFS= read -r -n1 c; do printf '%s' "$c"; sleep 0.035; done; printf '\n\n'; sleep 1; }

wipe
beat "The platform is already in this repository. Kiro finds it without being told."
quiet "$ ls .kiro/steering/"
ls -1 .kiro/steering/ | sed 's/^/    /'
sleep 3

beat "That is where the conventions live. Sizes, network tiers, budgets, cost centres."
quiet "$ grep -A6 'Known cost centres' .kiro/steering/cost.md"
grep -A8 "Known cost centres" .kiro/steering/cost.md | tail -7 | sed 's/^/    /'
sleep 4

beat "And the skill is the same file Claude Code uses. Not a translation of it."
quiet "$ ls -l .claude/skills/provision-service"
ls -l .claude/skills/provision-service | sed 's/^/    /'
sleep 4

beat "Now one sentence. Watch what it reads before it writes anything."
typed 'kiro-cli chat "I need a small postgres database for the orders service in dev, owner checkout-team"'

# Unfiltered on purpose: the tool calls are the evidence.
kiro-cli chat --no-interactive --trust-all-tools \
  "I need a small postgres database for the orders service in dev, owner checkout-team"
sleep 4

beat "It never wrote Terraform. It wrote this."
quiet "$ cat services/orders/service.yaml"
if [ -f services/orders/service.yaml ]; then
  cat services/orders/service.yaml | sed 's/^/    /'
  printf '\n    \033[1m%s lines.\033[0m It found CC-4472 itself, from naming.md.\n' \
    "$(wc -l < services/orders/service.yaml | tr -d ' ')"
else
  printf '    \033[1;31mno manifest produced\033[0m\n'
fi
sleep 5

beat "And the rings check it exactly as they check everything else."
quiet "$ ./platform/bin/check.sh"
./platform/bin/check.sh 2>&1 | sed 's/^/    /'
sleep 3

printf '\n\033[1;36m    One sentence. Twelve lines. Nothing applied.\033[0m\n'
printf '\033[1;36m    Read the world. Propose the change. Never apply it.\033[0m\n\n'
sleep 4
