#!/usr/bin/env bash
# The local mirror of what CI runs on every pull request.
#
#   ring 1  schema shape, then static analysis of the module
#   ring 2  contextual policy, environment-aware
#   render  manifest -> tfvars, the deterministic boundary
#   verify  terraform validates what the renderer produced
#
# Needs python3 and conftest. Terraform and checkov steps are skipped with a
# note when those tools are absent, so a fresh clone still gets useful output.
set -uo pipefail
cd "$(dirname "$0")/../.."

PY=python3
[ -x .venv/bin/python ] && PY=.venv/bin/python

fail=0
manifests=(services/*/service.yaml)

echo "== ring 1: schema =="
"$PY" platform/bin/validate.py "${manifests[@]}" || fail=1

echo
echo "== ring 2: policy =="
conftest test --policy platform/policies --namespace platform.service "${manifests[@]}" || fail=1

echo
echo "== render: manifest -> tfvars =="
"$PY" platform/bin/render.py "${manifests[@]}" || fail=1

echo
echo "== ring 2: policy over a plan =="
for fixture in platform/evals/plans/good-plan.json; do
  conftest test --policy platform/policies --namespace platform.plan "$fixture" || fail=1
done
# The bad fixture must be refused. A policy that stops catching things is worse
# than no policy, so the suite asserts the denial rather than assuming it.
if conftest test --policy platform/policies --namespace platform.plan \
     platform/evals/plans/bad-plan.json >/dev/null 2>&1; then
  echo "FAIL    bad-plan.json was NOT refused. Plan policy has regressed."
  fail=1
else
  echo "OK      bad-plan.json correctly refused"
fi

echo
echo "== ring 1: module static analysis =="
if [ -x .venv/bin/checkov ]; then
  .venv/bin/checkov -d platform/modules/service --config-file .checkov.yaml 2>&1 \
    | grep -E "Passed checks|FAILED for" || true
  # shellcheck disable=SC2181
  .venv/bin/checkov -d platform/modules/service --config-file .checkov.yaml >/dev/null 2>&1 || fail=1
else
  echo "SKIP    checkov not installed (pip install -r requirements.txt)"
fi

echo
echo "== verify: terraform =="
if command -v terraform >/dev/null 2>&1; then
  for dir in platform/modules/service deploy; do
    if [ -d "$dir/.terraform" ]; then
      (cd "$dir" && terraform validate -no-color) || fail=1
    else
      echo "SKIP    $dir not initialised (terraform -chdir=$dir init -backend=false)"
    fi
  done
else
  echo "SKIP    terraform not installed"
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "PASS  every ring clean"
else
  echo "FAIL  see messages above"
fi
exit "$fail"
