terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.80"
    }

    # Application Signals SLOs are not in the classic AWS provider as of 6.66,
    # so the SLO comes from Cloud Control. Convenient side effect: AWSCC
    # resources are exactly what CloudFormation Guard Hooks evaluate, which is
    # how ring 3 gets a deploy-time gate on the same resource.
    awscc = {
      source  = "hashicorp/awscc"
      version = ">= 1.0"
    }

    random = {
      source  = "hashicorp/random"
      version = ">= 3.6"
    }
  }
}
