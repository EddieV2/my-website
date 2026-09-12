# ---------------------------------------------------------------------------
# CloudFront access logs (standard logging v2) -> S3.
#
# The RUM beacon answers "how fast was it for real users". It cannot answer
# "who came, from where, and what did they read" -- it is client-side, so
# anything with JavaScript restrictions, a blocker, or Do Not Track is
# invisible to it, which is exactly the population worth knowing about here.
# Server-side access logs see every request regardless.
#
# v2 (rather than the legacy logging_config block on the distribution) for two
# reasons: per-field selection, and no S3 bucket ACL requirement -- legacy
# logging needs ACLs re-enabled on the bucket, which is a worse security
# posture than the bucket policy this uses.
#
# Region note: CloudFront is a global service whose logs are delivered through
# us-east-1. The single provider in main.tf is already us-east-1.
# ---------------------------------------------------------------------------

data "aws_caller_identity" "logs" {}

locals {
  # Bucket names are globally unique; the account id keeps this collision-free
  # without needing random state.
  logs_bucket_name = "${replace(var.domain_name, ".", "-")}-cf-logs-${data.aws_caller_identity.logs.account_id}"

  # Every field worth having. c-ip is included deliberately -- see the privacy
  # note on observability.html, which is written to match this list.
  # asn is the signal that turns an anonymous hit into "someone on a corporate
  # network": it resolves to the viewer's network operator, so a visit from
  # inside a company's own range names that company. A visitor on home
  # broadband or mobile resolves to their ISP instead, so treat it as a strong
  # hint, never proof.
  log_fields = [
    "date",
    "time",
    "timestamp(ms)",
    "c-ip",
    "asn",
    "c-country",
    "cs-uri-stem",
    "cs-uri-query",
    "cs(Referer)",
    "cs(User-Agent)",
    "sc-status",
    "sc-bytes",
    "time-taken",
    "time-to-first-byte",
    "x-edge-location",
    "x-edge-result-type",
    "x-edge-detailed-result-type",
    "cs-protocol",
    "cs-protocol-version",
    "x-host-header",
  ]
}

resource "aws_s3_bucket" "logs" {
  bucket = local.logs_bucket_name
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket                  = aws_s3_bucket.logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Logs carry IP addresses, so they get a fixed life rather than accumulating
# forever. 90 days covers a job search without becoming an archive.
resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    id     = "expire-access-logs"
    status = "Enabled"
    filter {}
    expiration {
      days = 90
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  # Athena query results, cleaned up aggressively -- they are derived data.
  rule {
    id     = "expire-athena-results"
    status = "Enabled"
    filter {
      prefix = "athena-results/"
    }
    expiration {
      days = 7
    }
  }
}

# CloudWatch's vended-logs delivery service writes the objects, so it needs
# explicit permission on the bucket. Scoped to this account's delivery sources.
resource "aws_s3_bucket_policy" "logs_delivery" {
  bucket = aws_s3_bucket.logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AWSLogsDeliveryWrite"
      Effect    = "Allow"
      Principal = { Service = "delivery.logs.amazonaws.com" }
      Action    = "s3:PutObject"
      Resource  = "${aws_s3_bucket.logs.arn}/*"
      Condition = {
        StringEquals = {
          "s3:x-amz-acl"      = "bucket-owner-full-control"
          "aws:SourceAccount" = data.aws_caller_identity.logs.account_id
        }
        ArnLike = {
          "aws:SourceArn" = "arn:aws:logs:us-east-1:${data.aws_caller_identity.logs.account_id}:delivery-source:*"
        }
      }
    }]
  })
}

# --- The delivery pipeline: source -> destination -> delivery ---------------

resource "aws_cloudwatch_log_delivery_source" "cloudfront" {
  name         = "evsite-cloudfront-access-logs"
  log_type     = "ACCESS_LOGS"
  resource_arn = aws_cloudfront_distribution.site.arn
}

resource "aws_cloudwatch_log_delivery_destination" "s3" {
  name          = "evsite-cloudfront-logs-s3"
  output_format = "parquet"

  delivery_destination_configuration {
    destination_resource_arn = aws_s3_bucket.logs.arn
  }
}

resource "aws_cloudwatch_log_delivery" "cloudfront_to_s3" {
  delivery_source_name     = aws_cloudwatch_log_delivery_source.cloudfront.name
  delivery_destination_arn = aws_cloudwatch_log_delivery_destination.s3.arn
  record_fields            = local.log_fields

  # CreateDelivery rejected two different custom suffix paths with an opaque
  # "ValidationException: Provided suffixPath is invalid" -- both used static
  # key= text with Hive mode on, and the API disagrees with the documented
  # example. Rather than keep guessing at an undocumented grammar, this matches
  # the configuration AWS publishes as valid in DescribeConfigurationTemplates:
  #   "s3DeliveryConfiguration": { "suffixPath": "", "enableHiveCompatiblePath": false }
  # CloudFront still writes a dated prefix of its own, and Athena reads it with
  # partition projection, so nothing downstream depends on a custom layout.
  s3_delivery_configuration {
    suffix_path                 = ""
    enable_hive_compatible_path = false
  }

  depends_on = [aws_s3_bucket_policy.logs_delivery]
}

output "logs_bucket" {
  description = "S3 bucket holding CloudFront access logs"
  value       = aws_s3_bucket.logs.bucket
}
