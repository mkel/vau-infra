# The account's shared, account-level Web ACL.
#
# This is the ONE Web ACL every project's CloudFront distribution in this
# account associates (web_acl_id) for edge rate limiting. vau-maillist
# deployments use waf_mode = "external" and take this root's web_acl_arn
# output; other backend components reference the same ARN and get their own
# rules added HERE, never from their own repositories.
#
# One CLOUDFRONT-scoped Web ACL can be associated with any number of
# distributions in the account, and the signup rate rule aggregates on source
# IP *and* Host, so each site gets its own per-IP counters. The fixed cost —
# $5/month for the ACL plus $1/month per rule, plus $0.60 per million
# inspected requests — is paid once, however many sites share it.
#
# Every site in the account depends on this ACL. Read CLAUDE.md in the repo
# root before changing anything.

terraform {
  required_version = ">= 1.9"

  backend "s3" {
    bucket       = "vau-terraform-state-bucket"
    key          = "vau-infra/shared-web-acl/terraform.tfstate"
    region       = "eu-west-1"
    profile      = "tg"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# A CLOUDFRONT-scoped Web ACL can only be created in us-east-1, whatever region
# the deployments themselves use.
#
# allowed_account_ids refuses to run against anything unexpected — a stale
# profile, an exported AWS_PROFILE you forgot about, or an assumed role that
# expired back to a default. Without it, a wrong profile silently creates the
# ACL in the wrong account, and every deployment pointing at the ARN of the
# right one fails to find it.
provider "aws" {
  region  = "us-east-1"
  profile = var.aws_profile

  allowed_account_ids = var.aws_account_id == null ? null : [var.aws_account_id]

  default_tags {
    tags = var.tags
  }
}

variable "aws_profile" {
  description = "AWS CLI profile to run as. Null uses the ambient credential chain."
  type        = string
  default     = null
}

variable "aws_account_id" {
  description = "Account this ACL belongs in. Guards against applying with the wrong credentials."
  type        = string
  default     = null
}

variable "name" {
  description = "Name of the Web ACL. Account-level, not per-site."
  type        = string
  default     = "shared-signups"
}

variable "rate_limit_requests" {
  description = "Requests permitted per evaluation window, per source IP per host. AWS WAF's minimum is 10."
  type        = number
  default     = 20

  validation {
    condition     = var.rate_limit_requests >= 10
    error_message = "AWS WAF requires a rate limit of at least 10."
  }
}

variable "rate_limit_window_seconds" {
  description = "Rate-based rule evaluation window. AWS WAF accepts only 60, 120, 300 or 600."
  type        = number
  default     = 60

  validation {
    condition     = contains([60, 120, 300, 600], var.rate_limit_window_seconds)
    error_message = "rate_limit_window_seconds must be one of: 60, 120, 300, 600."
  }
}

variable "tags" {
  description = "Tags applied to the Web ACL."
  type        = map(string)
  default     = {}
}

resource "aws_wafv2_web_acl" "shared" {
  name  = var.name
  scope = "CLOUDFRONT"

  default_action {
    allow {}
  }

  rule {
    name     = "signup-rate-limit"
    priority = 0

    action {
      block {
        custom_response {
          response_code = 429
        }
      }
    }

    statement {
      rate_based_statement {
        limit                 = var.rate_limit_requests
        evaluation_window_sec = var.rate_limit_window_seconds
        aggregate_key_type    = "CUSTOM_KEYS"

        # Aggregating on source IP *and* Host is what makes a shared ACL safe:
        # the same NAT IP hitting two different sites lands in two counters.
        custom_key {
          ip {}
        }

        custom_key {
          header {
            name = "host"

            # Required, not stylistic. CloudFront matches alternate domain
            # names case-insensitively while WAF aggregates on the literal
            # value, so without this Example.com and example.com would be two
            # counters with two full budgets.
            text_transformation {
              priority = 0
              type     = "LOWERCASE"
            }
          }
        }

        # Narrow the rule to the signup request itself, so the shared rule
        # does not count unrelated traffic.
        scope_down_statement {
          and_statement {
            statement {
              byte_match_statement {
                search_string         = "POST"
                positional_constraint = "EXACTLY"

                field_to_match {
                  method {}
                }

                text_transformation {
                  priority = 0
                  type     = "NONE"
                }
              }
            }

            statement {
              byte_match_statement {
                search_string         = "/v1/signups"
                positional_constraint = "EXACTLY"

                field_to_match {
                  uri_path {}
                }

                text_transformation {
                  priority = 0
                  type     = "LOWERCASE"
                }
              }
            }
          }
        }
      }
    }

    visibility_config {
      # Request logging is deliberately off: it persists client IP addresses.
      # Sampling is off for the same reason. Metrics carry counts only.
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-signup-rate-limit"
      sampled_requests_enabled   = false
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = var.name
    sampled_requests_enabled   = false
  }
}

output "web_acl_arn" {
  description = "Pass this as waf_external_web_acl_arn to every deployment, and as web_acl_id on every distribution."
  value       = aws_wafv2_web_acl.shared.arn
}
