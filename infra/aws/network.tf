locals {
  enabled    = var.enable_cloud ? 1 : 0
  name       = "devsecops-lab"
  account    = var.sandbox_account_id
  trail_arn  = "arn:aws:cloudtrail:${var.region}:${local.account}:trail/${local.name}"
  audit_path = "audit"
}

data "aws_availability_zones" "sandbox" {
  count = local.enabled
  state = "available"
}

resource "aws_vpc" "lab" {
  count                = local.enabled
  cidr_block           = "10.77.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  lifecycle {
    precondition {
      condition     = local.account != "000000000000" && startswith(var.trusted_workload_role_arn, "arn:aws:iam::${local.account}:role/")
      error_message = "Authorize a dedicated account and a workload role from that account before provisioning."
    }
  }
}

resource "aws_default_security_group" "lab" {
  count  = local.enabled
  vpc_id = aws_vpc.lab[0].id
}

resource "aws_subnet" "private" {
  count                   = var.enable_cloud ? 2 : 0
  vpc_id                  = aws_vpc.lab[0].id
  availability_zone       = sort(data.aws_availability_zones.sandbox[0].names)[count.index]
  cidr_block              = cidrsubnet(aws_vpc.lab[0].cidr_block, 8, count.index + 1)
  map_public_ip_on_launch = false
}

resource "aws_route_table" "private" {
  count  = local.enabled
  vpc_id = aws_vpc.lab[0].id
}

resource "aws_route_table_association" "private" {
  count          = var.enable_cloud ? 2 : 0
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[0].id
}

resource "aws_security_group" "workload" {
  count       = local.enabled
  name_prefix = "desk-workload-"
  description = "Allow connections only to the private AWS interface endpoints."
  vpc_id      = aws_vpc.lab[0].id
}

resource "aws_security_group" "endpoint" {
  count       = local.enabled
  name_prefix = "desk-endpoint-"
  description = "Accept HTTPS from the lab workload security group."
  vpc_id      = aws_vpc.lab[0].id
}

resource "aws_vpc_security_group_ingress_rule" "endpoint" {
  count                        = local.enabled
  security_group_id            = aws_security_group.endpoint[0].id
  referenced_security_group_id = aws_security_group.workload[0].id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  description                  = "Private AWS service HTTPS from the workload only."
}

resource "aws_vpc_security_group_egress_rule" "workload" {
  count                        = local.enabled
  security_group_id            = aws_security_group.workload[0].id
  referenced_security_group_id = aws_security_group.endpoint[0].id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  description                  = "Workload HTTPS only to the private AWS interface endpoints."
}

resource "aws_vpc_endpoint" "secrets" {
  count               = local.enabled
  vpc_id              = aws_vpc.lab[0].id
  service_name        = "com.amazonaws.${var.region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.endpoint[0].id]
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = "*"
      Action    = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource  = aws_secretsmanager_secret.desk[0].arn
      Condition = { ArnEquals = { "aws:PrincipalArn" = aws_iam_role.desk[0].arn } }
    }]
  })
}

resource "aws_vpc_endpoint" "sts" {
  count               = local.enabled
  vpc_id              = aws_vpc.lab[0].id
  service_name        = "com.amazonaws.${var.region}.sts"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.endpoint[0].id]
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = "*"
      Action    = "sts:AssumeRole"
      Resource  = aws_iam_role.desk[0].arn
      Condition = { ArnEquals = { "aws:PrincipalArn" = var.trusted_workload_role_arn } }
    }]
  })
}
