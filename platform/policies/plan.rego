package platform.plan

# Ring 2, second half: policy over the Terraform plan rather than the manifest.
#
# The manifest check asks "is this a reasonable request". This asks "is what
# Terraform is about to create acceptable", which is a different question with
# a different failure mode. A module bug, a bad default or a stale provider can
# all produce a dangerous plan from a perfectly legal manifest.
#
# It also catches the case the manifest check structurally cannot: someone
# editing the module itself. The manifest did not change, so ring 2's first
# half sees nothing, and this is the only gate that would notice.
#
# Input is `terraform show -json tfplan`.

import rego.v1

resources contains r if {
	some change in input.resource_changes
	change.change.actions[_] in ["create", "update"]
	r := {
		"type": change.type,
		"address": change.address,
		"after": object.get(change, ["change", "after"], {}),
	}
}

msg(what, why, fix) := sprintf(
	"DENIED  %s\n        Why:     %s\n        Fix:     %s",
	[what, why, fix],
)

# --------------------------------------------------------------------------
# databases
# --------------------------------------------------------------------------

deny contains m if {
	some r in resources
	r.type == "aws_db_instance"
	r.after.publicly_accessible == true

	m := msg(
		sprintf("%s would be publicly accessible", [r.address]),
		"databases belong in the isolated tier with no internet route, see .kiro/steering/network.md",
		"this should be impossible from a manifest. If you are seeing it, the module has a bug, so fix the module rather than the manifest",
	)
}

deny contains m if {
	some r in resources
	r.type == "aws_db_instance"
	r.after.storage_encrypted == false

	m := msg(
		sprintf("%s would be unencrypted at rest", [r.address]),
		"every database this platform creates is encrypted, without exception",
		"set storage_encrypted in the module. There is no manifest field for this and there should not be one",
	)
}

# --------------------------------------------------------------------------
# networking
# --------------------------------------------------------------------------

# A security group rule that opens a database port to a CIDR rather than to
# another security group. The module chains groups by reference, so a CIDR here
# means something has gone wrong.
deny contains m if {
	some r in resources
	r.type == "aws_vpc_security_group_ingress_rule"
	r.after.cidr_ipv4 == "0.0.0.0/0"
	r.after.from_port in [3306, 5432, 6379, 27017]

	m := msg(
		sprintf("%s opens a database port to the whole internet", [r.address]),
		"database ports are reachable from the task security group only, never from a CIDR",
		"reference the task security group instead of a CIDR block",
	)
}

# --------------------------------------------------------------------------
# iam
# --------------------------------------------------------------------------

# Catches a wildcard action paired with a wildcard resource, which is the shape
# of an accidental admin grant. Narrower wildcards are allowed: some AWS APIs,
# X-Ray among them, have no resource-level permissions at all.
deny contains m if {
	some r in resources
	r.type in ["aws_iam_role_policy", "aws_iam_policy"]
	doc := json.unmarshal(r.after.policy)
	some statement in doc.Statement
	statement.Effect == "Allow"
	wildcard_action(statement)
	wildcard_resource(statement)

	m := msg(
		sprintf("%s grants * on *", [r.address]),
		"that is administrator access. 'I will narrow it later' is how an agent ended up with the credentials that deleted a production database and its backups in nine seconds on 25 April 2026",
		"list the specific actions and scope them to resources this service owns",
	)
}

wildcard_action(statement) if statement.Action == "*"

wildcard_action(statement) if "*" in statement.Action

wildcard_resource(statement) if statement.Resource == "*"

wildcard_resource(statement) if "*" in statement.Resource

# --------------------------------------------------------------------------
# tagging
#
# Untagged spend cannot be attributed, and unattributable spend never gets
# cleaned up because nobody believes it is theirs.
# --------------------------------------------------------------------------

taggable := {
	"aws_db_instance",
	"aws_ecs_cluster",
	"aws_ecs_service",
	"aws_lb",
	"aws_secretsmanager_secret",
	"aws_cloudwatch_log_group",
}

deny contains m if {
	some r in resources
	r.type in taggable
	tags := object.get(r.after, "tags", {})
	required := {"Service", "Owner", "CostCentre", "Environment"}
	missing := required - {k | some k, _ in tags}
	count(missing) > 0

	m := msg(
		sprintf("%s is missing required tags: %s", [r.address, concat(", ", sort(missing))]),
		"untagged spend cannot be attributed to a team, see .kiro/steering/cost.md",
		"the module applies these from metadata. If they are missing, the module is not merging local.tags into this resource",
	)
}
