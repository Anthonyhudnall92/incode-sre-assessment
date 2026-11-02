# Three subnet tiers per AZ:
#   public   /24  - ALB + NAT only. No instances get public IPs.
#   private  /20  - EKS nodes and pods (VPC CNI gives pods VPC IPs, so size generously).
#   database /24  - RDS only. Route table has NO internet or NAT route.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.21"

  name = var.name
  cidr = var.cidr
  azs  = var.azs

  public_subnets   = [for i, _ in var.azs : cidrsubnet(var.cidr, 8, i)]      # 10.40.0.0/24, 10.40.1.0/24
  database_subnets = [for i, _ in var.azs : cidrsubnet(var.cidr, 8, i + 10)] # 10.40.10.0/24, 10.40.11.0/24
  private_subnets  = [for i, _ in var.azs : cidrsubnet(var.cidr, 4, i + 1)]  # 10.40.16.0/20, 10.40.32.0/20

  enable_dns_hostnames = true
  enable_dns_support   = true

  map_public_ip_on_launch = false

  enable_nat_gateway     = true
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = !var.single_nat_gateway

  create_database_subnet_group           = true
  create_database_subnet_route_table     = true
  create_database_internet_gateway_route = false
  create_database_nat_gateway_route      = false

  # Strip all rules from the default security group so nothing can
  # accidentally use it.
  manage_default_security_group  = true
  default_security_group_ingress = []
  default_security_group_egress  = []

  # VPC flow logs -> CloudWatch for network forensics.
  enable_flow_log                                 = true
  create_flow_log_cloudwatch_log_group            = true
  create_flow_log_cloudwatch_iam_role             = true
  vpc_flow_log_iam_role_name                      = "${var.name}-vpc-flow-logs"
  vpc_flow_log_iam_role_use_name_prefix           = false
  vpc_flow_log_permissions_boundary               = var.permissions_boundary_arn
  vpc_flow_log_iam_policy_name                    = "${var.name}-vpc-flow-logs"
  vpc_flow_log_iam_policy_use_name_prefix         = false
  flow_log_max_aggregation_interval               = 60
  flow_log_cloudwatch_log_group_retention_in_days = var.log_retention_days
  flow_log_cloudwatch_log_group_kms_key_id        = var.logs_kms_key_arn

  # Subnet discovery tags for the AWS Load Balancer Controller.
  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = 1
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = 1
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}
