terraform {
  required_version = ">= 1.9.0, < 2.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.46.0"
    }
  }
}

provider "aws" {
  region              = var.region
  allowed_account_ids = [var.sandbox_account_id]

  default_tags {
    tags = {
      Project     = "cloud-native-devsecops-lab"
      Environment = "isolated-sandbox"
      ManagedBy   = "opentofu"
    }
  }
}

variable "enable_cloud" {
  type        = bool
  default     = false
  description = "Create resources only with explicit approval and a dedicated sandbox account."
}

variable "region" {
  type        = string
  default     = "eu-west-1"
  description = "Sandbox AWS Region."
}

variable "sandbox_account_id" {
  type        = string
  description = "Expected account ID for both the provider and the workload trust principal."
  default     = "000000000000"

  validation {
    condition     = can(regex("^[0-9]{12}$", var.sandbox_account_id))
    error_message = "An AWS account ID must contain 12 digits."
  }
}

variable "trusted_workload_role_arn" {
  type        = string
  description = "Existing workload role ARN in the dedicated sandbox account."
  default     = ""

  validation {
    condition     = var.trusted_workload_role_arn == "" || can(regex("^arn:aws:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]+$", var.trusted_workload_role_arn))
    error_message = "Use the ARN of one IAM role with commercial AWS partition syntax."
  }
}
