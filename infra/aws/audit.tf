resource "aws_kms_key" "audit" {
  count                   = local.enabled
  description             = "Encrypt dedicated CloudTrail security logs."
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableAccountIAM"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${local.account}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowTrailEncryption"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "kms:GenerateDataKey*"
        Resource  = "*"
        Condition = {
          StringEquals = { "aws:SourceArn" = local.trail_arn }
          StringLike   = { "kms:EncryptionContext:aws:cloudtrail:arn" = "arn:aws:cloudtrail:*:${local.account}:trail/${local.name}" }
        }
      },
      {
        Sid       = "AllowTrailDescribeKey"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "kms:DescribeKey"
        Resource  = "*"
        Condition = { StringEquals = { "aws:SourceArn" = local.trail_arn } }
      }
    ]
  })
}

resource "aws_s3_bucket" "audit" {
  count         = local.enabled
  bucket_prefix = "dslab-trail-"
  force_destroy = false

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "audit" {
  count                   = local.enabled
  bucket                  = aws_s3_bucket.audit[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "audit" {
  count  = local.enabled
  bucket = aws_s3_bucket.audit[0].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "audit" {
  count  = local.enabled
  bucket = aws_s3_bucket.audit[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "audit" {
  count  = local.enabled
  bucket = aws_s3_bucket.audit[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.audit[0].arn
    }
  }
}

resource "aws_s3_bucket_policy" "audit" {
  count  = local.enabled
  bucket = aws_s3_bucket.audit[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "RequireTLS"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.audit[0].arn, "${aws_s3_bucket.audit[0].arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false", "aws:PrincipalIsAWSService" = "false" } }
      },
      {
        Sid       = "CloudTrailBucketACL"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.audit[0].arn
        Condition = { StringEquals = { "aws:SourceArn" = local.trail_arn } }
      },
      {
        Sid       = "CloudTrailWrite"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.audit[0].arn}/${local.audit_path}/AWSLogs/${local.account}/*"
        Condition = {
          StringEquals = {
            "aws:SourceArn" = local.trail_arn
            "s3:x-amz-acl"  = "bucket-owner-full-control"
          }
        }
      }
    ]
  })
  depends_on = [aws_s3_bucket_public_access_block.audit]
}

resource "aws_cloudtrail" "audit" {
  count                         = local.enabled
  name                          = local.name
  s3_bucket_name                = aws_s3_bucket.audit[0].id
  s3_key_prefix                 = local.audit_path
  kms_key_id                    = aws_kms_key.audit[0].arn
  enable_logging                = true
  enable_log_file_validation    = true
  include_global_service_events = true
  is_multi_region_trail         = true
  depends_on = [
    aws_s3_bucket_policy.audit,
    aws_s3_bucket_ownership_controls.audit,
    aws_s3_bucket_versioning.audit,
    aws_s3_bucket_server_side_encryption_configuration.audit,
  ]
}

output "workload_role_arn" {
  value       = try(aws_iam_role.desk[0].arn, null)
  description = "Role that can retrieve the designated secret."
}
