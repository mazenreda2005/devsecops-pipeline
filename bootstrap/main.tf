# Run ONCE, locally, with admin credentials:
#   terraform init && terraform apply -var github_repo=your-user/devsecops-pipeline
#
# Creates the GitHub OIDC identity provider and a deploy role that only
# this repository's main branch can assume. No long-lived AWS keys ever
# go into GitHub secrets.

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "github_repo" {
  description = "owner/name of the GitHub repository allowed to deploy."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repo))
    error_message = "Use the form owner/repo."
  }
}

variable "name" {
  type    = string
  default = "devsecops-demo"
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # AWS no longer validates this thumbprint for GitHub, but the API still requires a value.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# --- Encrypted, versioned bucket for the app's Terraform state ---
resource "aws_s3_bucket" "state" {
  # checkov:skip=CKV_AWS_18: State bucket access is already recorded by CloudTrail; access logs add little.
  # checkov:skip=CKV_AWS_144: State is versioned; cross-region replication is overkill for a demo app.
  # checkov:skip=CKV2_AWS_62: No consumers for state-change notifications.
  bucket = "${var.name}-tfstate-${local.account_id}"
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

# --- Deploy role, assumable only from main branch of one repo ---
data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name                 = "${var.name}-github-deploy"
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "deploy" {
  # checkov:skip=CKV_AWS_111: ecr:GetAuthorizationToken and kms:CreateKey do not support resource scoping.
  # checkov:skip=CKV_AWS_356: Same as above; every other statement is scoped to named resources.
  # checkov:skip=CKV_AWS_109: kms:PutKeyPolicy is needed to manage the ECR key Terraform creates.
  statement {
    sid       = "TerraformState"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
  }

  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrManageRepo"
    actions = [
      "ecr:CreateRepository", "ecr:DeleteRepository", "ecr:DescribeRepositories",
      "ecr:PutLifecyclePolicy", "ecr:GetLifecyclePolicy", "ecr:DeleteLifecyclePolicy",
      "ecr:PutImageScanningConfiguration", "ecr:PutImageTagMutability",
      "ecr:ListTagsForResource", "ecr:TagResource", "ecr:UntagResource",
      "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage",
    ]
    resources = ["arn:aws:ecr:${var.region}:${local.account_id}:repository/${var.name}"]
  }

  statement {
    sid       = "KmsCreateTaggedKeysOnly"
    actions   = ["kms:CreateKey", "kms:TagResource"]
    resources = ["*"] # kms:CreateKey cannot be scoped to a resource ARN
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/Project"
      values   = [var.name]
    }
  }

  statement {
    sid = "KmsManageOwnKeysOnly"
    actions = [
      "kms:DescribeKey", "kms:GetKeyPolicy", "kms:PutKeyPolicy", "kms:GetKeyRotationStatus",
      "kms:EnableKeyRotation", "kms:ListResourceTags", "kms:ScheduleKeyDeletion",
      "kms:CreateGrant", "kms:Decrypt", "kms:GenerateDataKey",
    ]
    resources = ["arn:aws:kms:${var.region}:${local.account_id}:key/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = [var.name]
    }
  }

  statement {
    sid       = "Identity"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "deploy"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}

output "deploy_role_arn" {
  description = "Set this as the AWS_DEPLOY_ROLE_ARN repository variable in GitHub."
  value       = aws_iam_role.deploy.arn
}

output "state_bucket" {
  description = "Set this as the TF_STATE_BUCKET repository variable in GitHub."
  value       = aws_s3_bucket.state.id
}
