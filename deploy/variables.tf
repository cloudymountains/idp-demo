# Mirrors the module's interface exactly. The renderer fills these in from a
# service.yaml, so this file and platform/modules/service/variables.tf move
# together. If they ever disagree, the renderer is the thing that breaks, which
# is the right place for that failure to surface.

variable "name" { type = string }
variable "environment" { type = string }
variable "owner" { type = string }
variable "cost_centre" { type = string }
variable "manifest_path" {
  type    = string
  default = ""
}

variable "runtime" {
  type = object({
    cpu      = optional(number, 512)
    memory   = optional(number, 1024)
    image    = optional(string, "public.ecr.aws/nginx/nginx:stable")
    replicas = optional(number, 2)
    port     = optional(number, 80)
  })
  default = {}
}

variable "ingress" {
  type = object({
    public            = optional(bool, false)
    path              = optional(string, "/")
    health_check_path = optional(string, "/")
  })
  default = null
}

variable "database" {
  type = object({
    engine    = string
    size      = string
    retention = optional(string, "7d")
    public    = optional(bool, false)
    multi_az  = optional(bool, false)
  })
  default = null
}

variable "permissions" {
  type = object({
    capabilities = optional(list(string), [])
  })
  default = {}
}

variable "observability" {
  type = object({
    slo_target_percent = optional(number, 99.0)
    log_retention_days = optional(number, 30)
  })
  default = {}
}
