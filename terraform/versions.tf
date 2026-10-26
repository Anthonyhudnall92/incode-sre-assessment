terraform {
  # >= 1.10 for S3 native state locking (use_lockfile).
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.95"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
  }

  # Partial configuration: values come from backend.hcl (gitignored).
  #   terraform init -backend-config=backend.hcl
  # See backend.hcl.example and the bootstrap/ stack.
  backend "s3" {}
}
