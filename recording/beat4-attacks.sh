#!/usr/bin/env bash
# Beat 4: the audience picks an attack, the platform refuses it.
# Paced for screen capture, so each denial has time to be read aloud.
set -u
cd "$(dirname "$0")/.."
PY=.venv/bin/python
pause() { sleep "${1:-2}"; }

say() { printf '\n\033[1;35m%s\033[0m\n\n' "$1"; }

say "The four attacks. Each one is refused by a different ring."
pause 2

n=1
for f in platform/evals/attacks/*.yaml; do
  title=$(head -1 "$f" | sed 's/^# *//')
  printf '\033[1;36m[%d] %s\033[0m\n' "$n" "$title"
  pause 1
  printf '\033[2m$ conftest test --namespace platform.service %s\033[0m\n' "$(basename "$f")"
  pause 1
  conftest test --policy platform/policies --namespace platform.service "$f" 2>&1 \
    | sed 's/^/    /'
  n=$((n+1))
  pause 3
done

say "And the manifest that is actually in the repo:"
pause 1
printf '\033[2m$ ./platform/bin/check.sh\033[0m\n'
pause 1
./platform/bin/check.sh 2>&1 | sed 's/^/    /'
pause 2
