provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }
}

# Used only to install cluster add-ons that are not EKS managed add-ons
# (AWS Load Balancer Controller). Auth is a short-lived token from the AWS CLI,
# so no kubeconfig or static credentials are involved.
provider "helm" {
  kubernetes {
    host                   = module.eks_cluster.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks_cluster.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks_cluster.cluster_name, "--region", var.region]
    }
  }
}
