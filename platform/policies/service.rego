package platform.service

# Ring 2 policy, evaluated against services/*/service.yaml before a plan is ever run.
#
# Every message in this file is written for two readers: the human reviewing the
# pull request, and the agent that will read the failure and try again. A message
# of the form "FAIL rule_db_size_dev" teaches the agent nothing and costs a round
# trip. A message that names the violation, the allowed values, the reason and the
# fix lets the agent self-correct inside the same session.
#
# That is why every deny below returns four lines: what, allowed, why, fix.

import rego.v1

# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

env := input.metadata.environment

svc := input.metadata.name

is_prod if env == "prod"

is_nonprod if env in ["dev", "staging"]

# Sizes permitted per environment. Prod may use anything; dev and staging are
# capped because the budget is capped. This is the relational constraint the
# JSON Schema deliberately does not express.
allowed_db_sizes := {
	"dev": {"small", "medium"},
	"staging": {"small", "medium", "large"},
	"prod": {"small", "medium", "large", "xlarge"},
}

# Ordered smallest to largest, so denial messages read "small, medium" rather
# than the alphabetical "medium, small". This is on screen during the demo
# climax, so the ordering is worth the four lines.
size_order := ["small", "medium", "large", "xlarge"]

ordered_sizes(permitted) := concat(", ", [s | some s in size_order; permitted[s]])

msg(what, allowed, why, fix) := sprintf(
	"DENIED  %s\n        Allowed: %s\n        Why:     %s\n        Fix:     %s",
	[what, allowed, why, fix],
)

# --------------------------------------------------------------------------
# ATTACK 1  "make the database xlarge, it is only dev"
# --------------------------------------------------------------------------

deny contains m if {
	size := input.spec.database.size
	permitted := allowed_db_sizes[env]
	not permitted[size]

	m := msg(
		sprintf("database.size=%s is not permitted in environment=%s", [size, env]),
		ordered_sizes(permitted),
		sprintf("non-production budget cap, see .kiro/steering/cost.md. An xlarge in dev costs roughly 16x a small and nothing in dev needs it.", []),
		"set spec.database.size to a permitted value, or request an exception via the platform-exception skill",
	)
}

# --------------------------------------------------------------------------
# ATTACK 2  "expose the database publicly, I need to debug it"
# --------------------------------------------------------------------------

deny contains m if {
	input.spec.database.public == true

	m := msg(
		"database.public=true is never permitted in any environment",
		"false",
		"databases live in isolated subnets with no internet route, see .kiro/steering/network.md. A publicly reachable database is an incident waiting for a scanner to find it.",
		"set spec.database.public to false and reach the database through the bastion documented in steering/network.md",
	)
}

# --------------------------------------------------------------------------
# ATTACK 3  "skip backups on the production database"
# --------------------------------------------------------------------------

deny contains m if {
	is_prod
	input.spec.database.retention in ["0d", "1d"]

	m := msg(
		sprintf("database.retention=%s is below the production minimum", [input.spec.database.retention]),
		"7d, 14d, 30d, 35d",
		"production data requires a 7 day minimum recovery window under the retention policy in steering/infra.md",
		"set spec.database.retention to 7d or longer",
	)
}

# A production database with no multi-AZ is a warning, not a denial. Not every
# production service needs it, and a policy that denies too much gets bypassed.
warn contains m if {
	is_prod
	not input.spec.database.multiAz

	m := sprintf(
		"WARN    database.multiAz=false in production for service=%s\n        Consider enabling it if this database is on a user-facing path.",
		[svc],
	)
}

# --------------------------------------------------------------------------
# ATTACK 4  "give the service admin permissions, I will narrow them later"
# --------------------------------------------------------------------------

deny contains m if {
	"admin" in input.spec.permissions.capabilities

	m := msg(
		"permissions.capabilities contains 'admin'",
		"s3:read-own-bucket, s3:write-own-bucket, sqs:consume-own-queue, sqs:publish-own-queue, secrets:read-own",
		"task roles are least-privilege by contract. 'I will narrow them later' is how an agent ended up with the credentials that deleted a production database and its backups in nine seconds on 25 April 2026.",
		"list only the capabilities the service actually uses, or request an exception via the platform-exception skill",
	)
}

# --------------------------------------------------------------------------
# baseline rules, always on
# --------------------------------------------------------------------------

# Public ingress in production needs an explicit owner acknowledgement, which in
# this platform means the service must also declare an SLO target.
deny contains m if {
	is_prod
	input.spec.ingress.public == true
	not input.spec.observability.sloTargetPercent

	m := msg(
		"ingress.public=true in production without an explicit spec.observability.sloTargetPercent",
		"any value from 90 to 99.99",
		"anything internet-facing in production must state the availability it promises, so ring 5 has a threshold to gate rollback on",
		"add spec.observability.sloTargetPercent, for example 99.5",
	)
}

# Fargate rejects invalid CPU and memory pairings at apply time with an opaque
# error. Catching it here turns a confusing deploy failure into a readable one.
valid_pairings := {
	256: {512, 1024, 2048},
	512: {1024, 2048, 3072, 4096},
	1024: {2048, 3072, 4096, 5120, 6144, 7168, 8192},
	2048: {4096, 8192, 16384},
	4096: {8192, 16384},
}

deny contains m if {
	cpu := object.get(input, ["spec", "runtime", "cpu"], 512)
	mem := object.get(input, ["spec", "runtime", "memory"], 1024)
	permitted := valid_pairings[cpu]
	not permitted[mem]

	m := msg(
		sprintf("runtime.cpu=%d with runtime.memory=%d is not a valid Fargate task size", [cpu, mem]),
		sprintf("with cpu=%d, memory must be one of %s", [cpu, concat(", ", [sprintf("%d", [v]) | some v in sort(permitted)])]),
		"Fargate only accepts specific CPU and memory combinations and rejects the rest at apply time with an unhelpful error",
		sprintf("set runtime.memory to one of the values above, or lower runtime.cpu", []),
	)
}

# Image registry allow-list. A public image in production is how supply chain
# problems arrive.
deny contains m if {
	is_prod
	image := object.get(input, ["spec", "runtime", "image"], "")
	not startswith(image, "111122223333.dkr.ecr.")

	m := msg(
		sprintf("runtime.image=%s is not from the company registry", [image]),
		"an image in the company ECR registry",
		"production images must be scanned and signed, and only ECR images go through that pipeline",
		"push the image to ECR and reference it by digest",
	)
}
