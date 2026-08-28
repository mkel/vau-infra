# The account's shared projects bucket.
#
# vauvideo-projects holds the deployed static assets of many projects, one
# top-level prefix per project.
# Each project's CloudFront distribution reads its own prefix and nothing
# else: the bucket policy grants s3:GetObject on a single prefix to a single
# distribution. A new project gets its read statement added HERE, in
# local.cloudfront_readers, never from its own repository.
#
# The bucket predates this configuration and was imported (see imports.tf).
# Everything below mirrors the live configuration exactly; a plan against an
# untouched bucket must show no changes.
#
# Every project in the account depends on this bucket. Read CLAUDE.md in the
# repo root before changing anything.

terraform {
  required_version = ">= 1.9"

  backend "s3" {
    bucket       = "vau-terraform-state-bucket"
    key          = "vau-infra/vauvideo-projects-bucket/terraform.tfstate"
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

# allowed_account_ids refuses to run against anything unexpected: a stale
# profile, an exported AWS_PROFILE you forgot about, or an assumed role that
# expired back to a default. Without it, a wrong profile creates a second
# bucket's worth of drift in the wrong account instead of failing loudly.
provider "aws" {
  region  = "eu-west-1"
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
  description = "Account this bucket belongs in. Guards against applying with the wrong credentials."
  type        = string
  default     = null
}

variable "bucket_name" {
  description = "Name of the shared projects bucket. Account-level, not per-project."
  type        = string
  default     = "vauvideo-projects"
}

variable "tags" {
  description = "Extra tags applied to every resource via provider default_tags."
  type        = map(string)
  default     = {}
}

data "aws_caller_identity" "current" {}

# One entry per project: which CloudFront distribution may read which prefix.
# Sids are kept exactly as the pre-import policy had them, which is why the
# vau-maillist one does not follow the pattern of the others.
locals {
  cloudfront_readers = [
    {
      sid             = "AllowCloudFrontReadTott"
      prefix          = "tott"
      distribution_id = "E3OZ3EDAHI16TQ"
    },
    {
      sid             = "AllowCloudFrontReadMkeltools"
      prefix          = "mkeltools"
      distribution_id = "E1TTEI83XU6T4C"
    },
    {
      sid             = "AllowCloudFrontReadStemmixr"
      prefix          = "stemmixr"
      distribution_id = "E16GYWW6DQ63V"
    },
    {
      sid             = "AllowCloudFrontReadVauMaillistSite"
      prefix          = "vau-maillist"
      distribution_id = "E1ZJEE25ZL29U0"
    },
  ]
}

resource "aws_s3_bucket" "projects" {
  bucket = var.bucket_name

  # The bucket holds every project's deployed assets and its name is baked
  # into every distribution's origin. A plan that shows it being destroyed or
  # replaced is wrong; stop and say so.
  lifecycle {
    prevent_destroy = true
  }

  # Pre-existing tags, kept verbatim from before the import.
  tags = {
    name    = "vauvideo-projects-s3"
    env     = "prod"
    project = "vauvideo-projects"
  }
}

# The bucket is private; CloudFront reaches it through the bucket policy's
# service-principal statements, which public-access-block does not affect.
resource "aws_s3_bucket_public_access_block" "projects" {
  bucket = aws_s3_bucket.projects.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "projects" {
  bucket = aws_s3_bucket.projects.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }

    bucket_key_enabled = false
  }
}

# Pre-existing CORS rule, kept verbatim from before the import: any origin
# may GET/HEAD. Objects are public web assets served via CloudFront, so this
# grants nothing the bucket policy has not already decided.
resource "aws_s3_bucket_cors_configuration" "projects" {
  bucket = aws_s3_bucket.projects.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "HEAD"]
    allowed_origins = ["*"]
    max_age_seconds = 31536000
  }
}

# Terraform owns the whole policy document. Adding a statement anywhere else
# (console, a project repo) will be reverted by the next apply here, so every
# per-project read grant must live in local.cloudfront_readers above.
resource "aws_s3_bucket_policy" "projects" {
  bucket = aws_s3_bucket.projects.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      for reader in local.cloudfront_readers : {
        Sid    = reader.sid
        Effect = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.projects.arn}/${reader.prefix}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = "arn:aws:cloudfront::${data.aws_caller_identity.current.account_id}:distribution/${reader.distribution_id}"
          }
        }
      }
    ]
  })
}

output "bucket_name" {
  description = "Name of the shared projects bucket."
  value       = aws_s3_bucket.projects.bucket
}

output "bucket_arn" {
  description = "ARN of the shared projects bucket."
  value       = aws_s3_bucket.projects.arn
}

output "bucket_regional_domain_name" {
  description = "Use this as the origin domain in CloudFront distributions."
  value       = aws_s3_bucket.projects.bucket_regional_domain_name
}
