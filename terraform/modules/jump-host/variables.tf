variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_id" {
  description = "Private subnet for the instance. It needs a route to the internet (NAT) for Systems Manager."
  type        = string
}

variable "permissions_boundary_arn" {
  type = string
}
