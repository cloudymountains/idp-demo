# The module's interface deliberately mirrors platform/schemas/service.v1.json.
# A renderer turns a service.yaml manifest into a tfvars file for this module,
# so there is exactly one mapping to maintain and no room for it to drift.
#
# Nothing here is free-form where the schema enumerates. Validation blocks
# repeat the schema's constraints so that a hand-edited tfvars file cannot get
# past the module either.

variable "name" {
  type        = string
  description = "Service name. Becomes the prefix of every resource name."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,28}[a-z0-9]$", var.name))
    error_message = "name must be lowercase DNS-safe, 3 to 30 characters."
  }
}

variable "environment" {
  type        = string
  description = "Deployment environment. Selects the VPC and drives sizing defaults."

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "owner" {
  type        = string
  description = "Owning team. Paged when the SLO burns."
}

variable "cost_centre" {
  type        = string
  description = "Finance cost centre. Tagged onto every resource."

  validation {
    condition     = can(regex("^CC-[0-9]{4}$", var.cost_centre))
    error_message = "cost_centre must look like CC-1234."
  }
}

variable "manifest_path" {
  type        = string
  description = "Path of the service.yaml that produced this. Tagged onto every resource so a mystery resource can be traced back to the pull request that created it."
  default     = ""
}

# ---------------------------------------------------------------------------
# runtime
# ---------------------------------------------------------------------------

variable "runtime" {
  description = "Container runtime configuration."

  type = object({
    cpu      = optional(number, 512)
    memory   = optional(number, 1024)
    image    = optional(string, "public.ecr.aws/nginx/nginx:stable")
    replicas = optional(number, 2)
    port     = optional(number, 80)
  })

  default = {}

  validation {
    condition     = contains([256, 512, 1024, 2048, 4096], var.runtime.cpu)
    error_message = "runtime.cpu must be one of: 256, 512, 1024, 2048, 4096."
  }

  validation {
    condition     = var.runtime.replicas >= 1 && var.runtime.replicas <= 10
    error_message = "runtime.replicas must be between 1 and 10."
  }
}

# ---------------------------------------------------------------------------
# ingress
# ---------------------------------------------------------------------------

variable "ingress" {
  description = "Load balancer configuration. Omit entirely for a service with no inbound traffic."

  type = object({
    public            = optional(bool, false)
    path              = optional(string, "/")
    health_check_path = optional(string, "/")
  })

  default = null
}

# ---------------------------------------------------------------------------
# database
# ---------------------------------------------------------------------------

variable "database" {
  description = "Managed database. Sizes are t-shirt sizes, never instance classes: the mapping lives in locals.tf where the platform team owns it."

  type = object({
    engine    = string
    size      = string
    retention = optional(string, "7d")
    public    = optional(bool, false)
    multi_az  = optional(bool, false)
  })

  default = null

  validation {
    condition     = var.database == null ? true : contains(["postgres", "mysql"], var.database.engine)
    error_message = "database.engine must be postgres or mysql."
  }

  validation {
    condition     = var.database == null ? true : contains(["small", "medium", "large", "xlarge"], var.database.size)
    error_message = "database.size must be one of: small, medium, large, xlarge."
  }

  # Ring 3. Policy denies this earlier and more readably, but the module refuses
  # too, so that a direct terraform apply that bypassed CI cannot create one.
  validation {
    condition     = var.database == null ? true : var.database.public == false
    error_message = "database.public is never permitted. Databases live in isolated subnets. Use the SSM bastion documented in .kiro/steering/network.md."
  }
}

# ---------------------------------------------------------------------------
# permissions
# ---------------------------------------------------------------------------

variable "permissions" {
  description = "Coarse capability names, never raw IAM. The module renders least-privilege policy documents from these."

  type = object({
    capabilities = optional(list(string), [])
  })

  default = {}

  validation {
    condition = alltrue([
      for c in var.permissions.capabilities : contains([
        "s3:read-own-bucket",
        "s3:write-own-bucket",
        "sqs:consume-own-queue",
        "sqs:publish-own-queue",
        "secrets:read-own",
      ], c)
    ])
    error_message = "Unknown capability. 'admin' is not grantable through this module at any time."
  }
}

# ---------------------------------------------------------------------------
# observability
# ---------------------------------------------------------------------------

variable "observability" {
  description = "Overrides only. The dashboard, alarms, SLO, log retention and tracing ship whether or not this is set. Observability is a property of having used the platform, not something a developer requests."

  type = object({
    slo_target_percent = optional(number, 99.0)
    log_retention_days = optional(number, 30)
  })

  default = {}

  validation {
    condition     = var.observability.slo_target_percent >= 90 && var.observability.slo_target_percent <= 99.99
    error_message = "observability.slo_target_percent must be between 90 and 99.99."
  }
}
