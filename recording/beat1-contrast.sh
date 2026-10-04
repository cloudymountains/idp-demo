#!/usr/bin/env bash
# Beats 1 and 3, side by side: the same request with and without the platform.
#
# The honest version of this beat. A 2026 model does not write insecure
# Terraform: the unguided run below sets storage_encrypted, publicly_accessible
# false and a managed master password without being asked. The failure is
# different, and it is worse.
set -u
cd "$(dirname "$0")/.."
say() { printf '\n\033[1;35m%s\033[0m\n\n' "$1"; }
cmd() { printf '\033[2m$ %s\033[0m\n' "$1"; sleep 1; }

say 'WITHOUT the platform: "I need a postgres database for a reporting service"'
sleep 1
cmd "ls recording/antidemo/"
ls -1 recording/antidemo/ | sed 's/^/    /'
printf '\n    \033[1m%s lines of Terraform across %s files\033[0m\n' \
  "$(cat recording/antidemo/*.tf | wc -l | tr -d ' ')" \
  "$(ls -1 recording/antidemo/*.tf | wc -l | tr -d ' ')"
sleep 3

say "And it is good Terraform. It chose these on its own:"
grep -hoE "storage_encrypted *= *true|publicly_accessible *= *false|manage_master_user_password *= *true" \
  recording/antidemo/*.tf | sort -u | sed 's/^/    /'
sleep 3

say "So what is wrong with it? It does not know anything about you."
sleep 1
grep -E "^variable \"(vpc_id|private_subnet_ids|allowed_cidr_blocks|instance_class)\"" \
  recording/antidemo/variables.tf | sed 's/variable //; s/ {//' | sed 's/^/    hands back to you:  /'
printf '\n    \033[1m%s free variables. No cost centre. No owner. No budget cap.\033[0m\n' \
  "$(grep -cE '^variable ' recording/antidemo/variables.tf)"
printf '    \033[1mNothing stops db.r5.8xlarge in dev.\033[0m\n'
sleep 4

say "WITH the platform. Same sentence."
sleep 1
cmd "cat services/reporting/service.yaml"
cat services/reporting/service.yaml | sed 's/^/    /'
printf '\n    \033[1m%s lines. One file. Written by an agent, reviewable by a human.\033[0m\n' \
  "$(wc -l < services/reporting/service.yaml | tr -d ' ')"
sleep 3

say "The agent found the cost centre itself, from the steering files."
cmd "grep -A5 'Known cost centres' .kiro/steering/cost.md"
grep -A7 "Known cost centres" .kiro/steering/cost.md | tail -6 | sed 's/^/    /'
sleep 3

say "And every value in it is enumerated, so policy can reason about it exactly."
cmd "./platform/bin/check.sh"
./platform/bin/check.sh 2>&1 | grep -E "ring|OK|PASS|tests" | sed 's/^/    /'
sleep 2
printf '\n\033[1;36m    389 lines you must review, or 12 lines a policy engine reviews for you.\033[0m\n\n'
sleep 2
