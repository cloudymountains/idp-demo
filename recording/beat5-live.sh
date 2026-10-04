#!/usr/bin/env bash
# Beat 5: the change is live, and the platform checks whether it worked.
# Read-only. Everything here was provisioned by the pipeline, not by this script.
set -u
cd "$(dirname "$0")/.."
export AWS_REGION=eu-west-1
PY=.venv/bin/python
say() { printf '\n\033[1;35m%s\033[0m\n\n' "$1"; }
cmd() { printf '\033[2m$ %s\033[0m\n' "$1"; sleep 1; }

say "One manifest. Ten lines. This is all the developer wrote."
cmd "cat services/checkout/service.yaml"
cat services/checkout/service.yaml | sed 's/^/    /'
sleep 3

say "The platform turned that into 31 resources."
cmd "terraform -chdir=deploy state list | wc -l"
terraform -chdir=deploy state list | wc -l | sed 's/^/    /'
sleep 2

say "It is running."
ALB=$(terraform -chdir=deploy output -raw url | sed 's|/checkout$||')
cmd "curl -s -o /dev/null -w '%{http_code}' $ALB"
printf '    HTTP '; curl -s -o /dev/null -w '%{http_code}\n' --max-time 10 "$ALB" | sed 's/^//'
sleep 2

say "And the developer never asked for any of this:"
cmd "aws cloudwatch list-dashboards --query 'DashboardEntries[].DashboardName'"
aws cloudwatch list-dashboards --query 'DashboardEntries[].DashboardName' --output text | tr '\t' '\n' | sed 's/^/    dashboard  /'
aws cloudwatch describe-alarms --query 'MetricAlarms[].AlarmName' --output text | tr '\t' '\n' | sed 's/^/    alarm      /'
aws application-signals list-service-level-objectives --query 'SloSummaries[].Name' --output text | tr '\t' '\n' | sed 's/^/    SLO        /'
aws logs describe-log-groups --log-group-name-prefix /platform/ --query 'logGroups[].logGroupName' --output text | tr '\t' '\n' | sed 's/^/    log group  /'
sleep 4

say "Ring 5. Prediction has a ceiling, so after apply the platform asks whether it actually worked."
cmd "slo_check.py --slo dev-checkout-availability --target 99.0"
$PY platform/bin/slo_check.py --slo dev-checkout-availability --target 99.0 --settle 0 --window 20 2>&1 | sed 's/^/    /'
sleep 4

say "The agent could read all of that. It could change none of it."
cmd "aws iam list-attached-role-policies --role-name dev-checkout-task-role"
aws iam list-attached-role-policies --role-name dev-checkout-task-role --query 'AttachedPolicies[].PolicyName' --output text | sed 's/^/    attached: /'
aws iam list-role-policies --role-name dev-checkout-task-role --query 'PolicyNames' --output text | tr '\t' '\n' | sed 's/^/    inline:   /'
sleep 3
printf '\n\033[1;36m    Read the world. Propose the change. Never apply it.\033[0m\n\n'
sleep 2
