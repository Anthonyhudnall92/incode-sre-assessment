# -----------------------------------------------------------------------------
# In-cluster add-ons installed with Helm
#
# Kept apart from the main stack (terraform/) so that the main stack only talks
# to AWS APIs. That lets GitHub Actions plan and apply it without reaching the
# Kubernetes API, which is restricted to admin_cidrs. This layer does reach the
# API, so it runs from an allowed network. Argo CD takes these over later.
#
# It finds the cluster and the controller's IAM role by their fixed names, so
# there is no dependency on the main stack's state.
#
#   terraform -chdir=addons init -backend-config=../terraform/backend.hcl \
#     -backend-config=key=sre-demo/addons.tfstate
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
  }

  backend "s3" {}
}

provider "aws" {
  region = var.region
}

data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

data "aws_iam_role" "lb_controller" {
  name = "${var.cluster_name}-lb-controller"
}

# Short-lived token from the AWS CLI; no kubeconfig or static credentials.
provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.region]
    }
  }
}

# Adopts the release the main stack used to manage, without reinstalling it.
import {
  to = helm_release.aws_load_balancer_controller
  id = "kube-system/aws-load-balancer-controller"
}

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.lb_controller_chart_version
  namespace  = "kube-system"

  # region/vpcId are passed explicitly because IMDS is not reachable
  # from pods (hop limit 1).
  set {
    name  = "clusterName"
    value = var.cluster_name
  }

  set {
    name  = "region"
    value = var.region
  }

  set {
    name  = "vpcId"
    value = data.aws_eks_cluster.this.vpc_config[0].vpc_id
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = data.aws_iam_role.lb_controller.arn
  }
}
