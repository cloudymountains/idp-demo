#!/usr/bin/env bash
# Destroy everything the recording created, then prove it.
#
# Written before anything was provisioned, on purpose. A teardown you write
# afterwards is a teardown you write while tired, and this is a root-credentialed
# account. It is safe to run repeatedly and safe to run after a partial failure.
#
#   ./demo/teardown.sh
set -uo pipefail
cd "$(dirname "$0")/.."

REGION="${AWS_REGION:-eu-west-1}"
fail=0

echo "== 1/3  destroy the service =="
if [ -f deploy/terraform.tfstate ]; then
  terraform -chdir=deploy destroy -auto-approve -input=false \
    -var-file="dev-checkout.tfvars.json" || fail=1
else
  echo "no service state, skipping"
fi

echo
echo "== 2/3  destroy the demo network =="
if [ -f demo/network/terraform.tfstate ]; then
  terraform -chdir=demo/network destroy -auto-approve -input=false || fail=1
else
  echo "no network state, skipping"
fi

echo
echo "== 3/3  sweep: anything left behind? =="
leftover=0
check() {
  local label="$1"; shift
  local out
  out=$("$@" 2>/dev/null | tr -d '[:space:]')
  if [ -n "$out" ] && [ "$out" != "None" ]; then
    echo "  STILL PRESENT  $label: $out"
    leftover=1
  else
    echo "  clean          $label"
  fi
}

check "VPCs"            aws ec2 describe-vpcs --region "$REGION" \
  --filters "Name=tag:ManagedBy,Values=platform" --query 'Vpcs[].VpcId' --output text
check "RDS instances"   aws rds describe-db-instances --region "$REGION" \
  --query 'DBInstances[].DBInstanceIdentifier' --output text
check "load balancers"  aws elbv2 describe-load-balancers --region "$REGION" \
  --query 'LoadBalancers[].LoadBalancerName' --output text
check "ECS clusters"    aws ecs list-clusters --region "$REGION" \
  --query 'clusterArns' --output text
check "NAT gateways"    aws ec2 describe-nat-gateways --region "$REGION" \
  --filter "Name=state,Values=available,pending" --query 'NatGateways[].NatGatewayId' --output text
check "secrets"         aws secretsmanager list-secrets --region "$REGION" \
  --query "SecretList[?starts_with(Name,'/dev/')].Name" --output text
check "SLOs"            aws application-signals list-service-level-objectives \
  --region "$REGION" --query 'SloSummaries[].Name' --output text

# Secrets Manager keeps deleted secrets for a recovery window unless forced.
echo
echo "  force-deleting any scheduled secrets"
for arn in $(aws secretsmanager list-secrets --region "$REGION" --include-planned-deletion \
    --query "SecretList[?starts_with(Name,'/dev/')].ARN" --output text 2>/dev/null); do
  aws secretsmanager delete-secret --region "$REGION" --secret-id "$arn" \
    --force-delete-without-recovery >/dev/null 2>&1 && echo "    forced: $arn"
done

# Log groups survive terraform destroy when a task wrote to them late.
for lg in $(aws logs describe-log-groups --region "$REGION" \
    --log-group-name-prefix /platform/ --query 'logGroups[].logGroupName' --output text 2>/dev/null); do
  aws logs delete-log-group --region "$REGION" --log-group-name "$lg" >/dev/null 2>&1 \
    && echo "    deleted log group: $lg"
done

echo
if [ "$leftover" -eq 0 ] && [ "$fail" -eq 0 ]; then
  echo "TEARDOWN CLEAN"
else
  echo "TEARDOWN INCOMPLETE - read the lines above and re-run"
  exit 1
fi
