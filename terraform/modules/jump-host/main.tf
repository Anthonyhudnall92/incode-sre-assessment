# -----------------------------------------------------------------------------
# SSM jump host for the private EKS API
#
# No SSH, no key pair, no inbound rules, no public IP. Admins reach the API
# with an SSM port-forwarding session through this instance and authenticate
# to Kubernetes as themselves: the instance has no Kubernetes access and its
# role can only talk to Systems Manager.
# -----------------------------------------------------------------------------

data "aws_partition" "current" {}

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_security_group" "this" {
  name        = "${var.name}-jump-host"
  description = "SSM jump host: no inbound; HTTPS out to SSM and the EKS API"
  vpc_id      = var.vpc_id

  egress {
    description = "HTTPS to Systems Manager (via NAT) and the EKS API (in the VPC)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name                 = "${var.name}-jump-host"
  description          = "SSM jump host: Systems Manager only"
  assume_role_policy   = data.aws_iam_policy_document.assume.json
  permissions_boundary = var.permissions_boundary_arn
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "this" {
  name = "${var.name}-jump-host"
  role = aws_iam_role.this.name
}

resource "aws_instance" "this" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = "t3.micro"
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.this.id]
  iam_instance_profile   = aws_iam_instance_profile.this.name
  monitoring             = true
  ebs_optimized          = true

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    http_endpoint               = "enabled"
  }

  root_block_device {
    encrypted   = true
    volume_type = "gp3"
    volume_size = 8
  }

  tags = { Name = "${var.name}-jump-host" }

  lifecycle {
    # A newer AMI should not replace the host mid-session; patch it with SSM
    # or replace it deliberately (terraform apply -replace).
    ignore_changes = [ami]
  }
}
