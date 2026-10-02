# Infrastructure the pipeline deploys: a hardened ECR repository for the app image.
# Checkov scans this folder on every push; insecure changes fail the build.

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # The pipeline passes these with -backend-config so nothing account-specific is committed.
  backend "s3" {}
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = var.name, ManagedBy = "terraform", Pipeline = "github-actions" }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "name" {
  type    = string
  default = "devsecops-demo"
}

resource "aws_kms_key" "ecr" {
  description         = "${var.name} ECR image encryption"
  enable_key_rotation = true
}

resource "aws_kms_key_policy" "ecr" {
  key_id = aws_kms_key.ecr.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AccountAdmin"
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
      Action    = "kms:*"
      Resource  = "*"
    }]
  })
}

data "aws_caller_identity" "current" {}

resource "aws_ecr_repository" "app" {
  name                 = var.name
  image_tag_mutability = "IMMUTABLE" # a tag can never be silently replaced

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.ecr.arn
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last 20 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 20
      }
      action = { type = "expire" }
    }]
  })
}

output "repository_url" {
  value = aws_ecr_repository.app.repository_url
}
