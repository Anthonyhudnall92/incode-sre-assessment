# -----------------------------------------------------------------------------
# Argo CD, and the apps it keeps in sync
#
# Kept apart from the main stack (terraform/) so that the main stack only talks
# to AWS APIs and GitHub Actions can plan and apply it. This layer reaches the
# Kubernetes API, which is private, so it runs through `make tunnel`.
#
# Terraform installs Argo CD and declares its Applications. From then on Argo
# CD owns everything they contain. Values that name the account or the
# environment come from the main stack's outputs and live only in the cluster,
# because this repository is public.
#
#   make addons
# -----------------------------------------------------------------------------

terraform {
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
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.38"
    }
  }

  backend "s3" {}
}

provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}

# The main stack's outputs: role ARNs, the database, the certificate, the
# domain. Read-only; this layer never writes that state.
data "terraform_remote_state" "main" {
  backend = "s3"
  config = {
    bucket = coalesce(var.state_bucket, "${var.cluster_name}-tfstate-${data.aws_caller_identity.current.account_id}-${var.region}")
    key    = "${var.cluster_name}/main.tfstate"
    region = var.region
  }
}

locals {
  main = data.terraform_remote_state.main.outputs
}

data "aws_eks_cluster" "this" {
  name = local.main.cluster_name
}

# Short-lived token from the AWS CLI; no kubeconfig or static credentials.
# The API is private: through the tunnel, connect to 127.0.0.1 but verify the
# certificate against the real endpoint name.
provider "helm" {
  kubernetes {
    host                   = coalesce(var.api_server_url, data.aws_eks_cluster.this.endpoint)
    tls_server_name        = var.api_server_url == null ? null : trimprefix(data.aws_eks_cluster.this.endpoint, "https://")
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", local.main.cluster_name, "--region", var.region]
    }
  }
}

provider "kubernetes" {
  host                   = coalesce(var.api_server_url, data.aws_eks_cluster.this.endpoint)
  tls_server_name        = var.api_server_url == null ? null : trimprefix(data.aws_eks_cluster.this.endpoint, "https://")
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.main.cluster_name, "--region", var.region]
  }
}

# The load balancer controller used to be a Helm release here. Argo CD now
# owns it (apps.tf); forget the release without uninstalling it.
removed {
  from = helm_release.aws_load_balancer_controller

  lifecycle {
    destroy = false
  }
}
