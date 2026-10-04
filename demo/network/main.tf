# The network the platform module expects to find.
#
# The module deliberately never creates a VPC and never falls back to the
# default one: it looks the environment up by tag and fails loudly if it is
# missing. So a recording needs this to exist first. It matches the topology
# described in .kiro/steering/network.md, because a demo that used a flat
# network would quietly contradict the talk.
#
# Temporary. demo/teardown.sh destroys it.

terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 5.80" }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      ManagedBy = "platform"
      Purpose   = "talk-recording"
    }
  }
}

variable "region" {
  type    = string
  default = "eu-west-1"
}

variable "environment" {
  type    = string
  default = "dev"
}

locals {
  cidr = "10.40.0.0/16"
  azs  = ["${var.region}a", "${var.region}b"]

  tiers = {
    public   = ["10.40.0.0/24", "10.40.1.0/24"]
    private  = ["10.40.10.0/24", "10.40.11.0/24"]
    isolated = ["10.40.20.0/24", "10.40.21.0/24"]
  }

  # Flattened so each subnet is one resource instance with a stable key.
  subnets = merge([
    for tier, cidrs in local.tiers : {
      for i, cidr in cidrs : "${tier}-${i}" => {
        tier = tier
        cidr = cidr
        az   = local.azs[i]
      }
    }
  ]...)
}

resource "aws_vpc" "this" {
  cidr_block           = local.cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  # The module finds the VPC by these two tags. Nothing else identifies it.
  tags = {
    Name        = "${var.environment}-platform"
    Environment = var.environment
  }
}

resource "aws_subnet" "this" {
  for_each = local.subnets

  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value.cidr
  availability_zone = each.value.az

  tags = {
    Name        = "${var.environment}-${each.key}"
    Tier        = each.value.tier
    Environment = var.environment
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.environment}-igw" }
}

# One NAT gateway, not one per availability zone. A deliberate cost/availability
# trade-off, and the same one .kiro/steering/cost.md documents so nobody
# "fixes" it later.
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.environment}-nat" }
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.this["public-0"].id
  tags          = { Name = "${var.environment}-nat" }
  depends_on    = [aws_internet_gateway.this]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${var.environment}-public" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }

  tags = { Name = "${var.environment}-private" }
}

# No routes at all. This is what makes the isolated tier isolated, and it is
# the second, independent reason a database here cannot be reached from the
# internet even if someone sets publicly_accessible by mistake.
resource "aws_route_table" "isolated" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.environment}-isolated" }
}

resource "aws_route_table_association" "this" {
  for_each = local.subnets

  subnet_id = aws_subnet.this[each.key].id
  route_table_id = (
    each.value.tier == "public" ? aws_route_table.public.id :
    each.value.tier == "private" ? aws_route_table.private.id :
    aws_route_table.isolated.id
  )
}

output "vpc_id" { value = aws_vpc.this.id }

output "tiers" {
  value = {
    for tier in keys(local.tiers) :
    tier => [for k, v in local.subnets : aws_subnet.this[k].id if v.tier == tier]
  }
}
