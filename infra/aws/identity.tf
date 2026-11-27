resource "aws_kms_key" "secrets" {
  count                   = local.enabled
  description             = "Encrypt the lab Secrets Manager entry."
  enable_key_rotation     = true
  deletion_window_in_days = 30
}

resource "aws_secretsmanager_secret" "desk" {
  count                   = local.enabled
  name                    = "${local.name}/desk/session-key"
  kms_key_id              = aws_kms_key.secrets[0].arn
  recovery_window_in_days = 30
}

resource "aws_iam_role" "desk" {
  count                = local.enabled
  name                 = "${local.name}-secret-reader"
  max_session_duration = 3600
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = var.trusted_workload_role_arn }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "read_secret" {
  count = local.enabled
  name  = "read-designated-secret"
  role  = aws_iam_role.desk[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = aws_secretsmanager_secret.desk[0].arn
        Condition = { StringEquals = { "aws:SourceVpce" = aws_vpc_endpoint.secrets[0].id } }
      },
      {
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = aws_kms_key.secrets[0].arn
        Condition = {
          StringEquals = {
            "kms:ViaService"                  = "secretsmanager.${var.region}.amazonaws.com"
            "kms:EncryptionContext:SecretARN" = aws_secretsmanager_secret.desk[0].arn
          }
        }
      }
    ]
  })
}
