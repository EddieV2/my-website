# ---------------------------------------------------------------------------
# evartanessian.dev — production hosting.
#
#   S3 (private, OAC-only) ← CloudFront (HTTPS, HTTP/3, security headers,
#   clean-URL function, www→apex redirect) ← ACM (us-east-1, DNS-validated)
#   Deploys: GitHub Actions via OIDC — no stored AWS keys anywhere.
#
# DNS lives at the registrar (not Route 53). Two manual DNS moments:
#   1. During first apply: create the ACM validation CNAMEs from the
#      `acm_validation_records` output — apply waits for validation.
#   2. After apply: point apex + www at `cloudfront_domain` (output).
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = "us-east-1" # CloudFront ACM certs must live in us-east-1
}

# --- Inputs ----------------------------------------------------------------

variable "domain_name" {
  description = "Apex domain for the site"
  type        = string
  default     = "evartanessian.dev"
}

variable "github_repository" {
  description = "owner/repo allowed to deploy via OIDC"
  type        = string
  default     = "EddieV2/my-website"
}

variable "github_owner_id" {
  description = "Numeric GitHub owner ID (immutable OIDC sub claims embed it for repos created after 2026-07-15)"
  type        = string
  default     = "2405059"
}

variable "github_repository_id" {
  description = "Numeric GitHub repository ID; leave empty until the repo exists (wildcard is used, still scoped to the owner ID)"
  type        = string
  default     = ""
}

variable "create_oidc_provider" {
  description = "Set false if this AWS account already has the GitHub Actions OIDC provider"
  type        = bool
  default     = true
}

locals {
  www_domain   = "www.${var.domain_name}"
  gh_owner     = split("/", var.github_repository)[0]
  gh_repo      = split("/", var.github_repository)[1]
  gh_repo_id   = var.github_repository_id != "" ? var.github_repository_id : "*"
  # Repos created ≥ 2026-07-15 emit immutable sub claims with numeric IDs;
  # keep the classic pattern too so nothing breaks either way.
  oidc_subjects = [
    "repo:${var.github_repository}:*",
    "repo:${local.gh_owner}@${var.github_owner_id}/${local.gh_repo}@${local.gh_repo_id}:*",
  ]
}

# --- S3: private bucket, CloudFront-only access ----------------------------

resource "aws_s3_bucket" "site" {
  bucket_prefix = "ev-personal-site-"
}

resource "aws_s3_bucket_public_access_block" "site" {
  bucket                  = aws_s3_bucket.site.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "cloudfront_only" {
  bucket = aws_s3_bucket.site.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFrontOAC"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.site.arn}/*"
      Condition = {
        StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.site.arn }
      }
    }]
  })
}

# --- ACM: apex + www, DNS-validated at the external registrar ---------------

resource "aws_acm_certificate" "site" {
  domain_name               = var.domain_name
  subject_alternative_names = [local.www_domain]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# Waits until the validation CNAMEs (see outputs) exist at the registrar.
resource "aws_acm_certificate_validation" "site" {
  certificate_arn = aws_acm_certificate.site.arn
  validation_record_fqdns = [
    for dvo in aws_acm_certificate.site.domain_validation_options : dvo.resource_record_name
  ]
}

# --- Security headers -------------------------------------------------------

resource "aws_cloudfront_response_headers_policy" "security" {
  name    = "ev-site-security-headers"
  comment = "HSTS preload, strict CSP, nosniff, no framing"

  security_headers_config {
    strict_transport_security {
      access_control_max_age_sec = 63072000 # 2 years
      include_subdomains         = true
      preload                    = true
      override                   = true
    }
    content_security_policy {
      # script-src stays 'self' because the theme bootstrap is an external file
      # (theme-init.js). 'unsafe-inline' styles are required by the reveal-delay
      # style attributes and the card-spotlight CSS variables.
      content_security_policy = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'; upgrade-insecure-requests"
      override                = true
    }
    frame_options {
      frame_option = "DENY"
      override     = true
    }
    content_type_options {
      override = true
    }
    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }
  }
}

# --- Clean URLs + www redirect ----------------------------------------------

resource "aws_cloudfront_function" "urls" {
  name    = "ev-site-urls"
  runtime = "cloudfront-js-2.0"
  comment = "www→apex 301 + extensionless URL rewrites for the private S3 origin"
  publish = true
  code    = file("${path.module}/function.js")
}

# --- CloudFront -------------------------------------------------------------

resource "aws_cloudfront_origin_access_control" "site" {
  name                              = "ev-personal-site-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "site" {
  enabled             = true
  is_ipv6_enabled     = true
  http_version        = "http2and3"
  default_root_object = "index.html"
  price_class         = "PriceClass_100"
  aliases             = [var.domain_name, local.www_domain]

  origin {
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_id                = "s3-site"
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }

  # RUM ingest Lambda (Function URL), reachable only through this behavior:
  # the shared-secret header is how the Lambda rejects direct URL calls.
  origin {
    domain_name = replace(replace(aws_lambda_function_url.rum.function_url, "https://", ""), "/", "")
    origin_id   = "rum-ingest"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    custom_header {
      name  = "X-Origin-Verify"
      value = random_password.origin_secret.result
    }
  }

  default_cache_behavior {
    target_origin_id           = "s3-site"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = "658327ea-f89d-4fab-a63d-7e88639e58f6" # AWS managed: CachingOptimized
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.urls.arn
    }
  }

  ordered_cache_behavior {
    path_pattern             = "/rum"
    target_origin_id         = "rum-ingest"
    viewer_protocol_policy   = "https-only"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    compress                 = false
    cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # AWS managed: CachingDisabled
    origin_request_policy_id = "b689b0a8-53d0-40ab-baf2-68738e2966ac" # AWS managed: AllViewerExceptHostHeader
  }

  # The OAC origin answers 403 for missing keys; show the styled 404 instead.
  custom_error_response {
    error_code         = 403
    response_code      = 404
    response_page_path = "/404.html"
  }
  custom_error_response {
    error_code         = 404
    response_code      = 404
    response_page_path = "/404.html"
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.site.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

# --- GitHub Actions OIDC: keyless deploys -----------------------------------

resource "aws_iam_openid_connect_provider" "github" {
  count           = var.create_oidc_provider ? 1 : 0
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  # thumbprint_list intentionally omitted: AWS validates GitHub's issuer
  # against its own trusted CA library.
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

locals {
  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
}

resource "aws_iam_role" "deploy" {
  name = "github-actions-ev-site-deploy"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
        StringLike   = { "token.actions.githubusercontent.com:sub" = local.oidc_subjects }
      }
    }]
  })
}

resource "aws_iam_role_policy" "deploy" {
  name = "deploy-site"
  role = aws_iam_role.deploy.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.site.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.site.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["cloudfront:CreateInvalidation"]
        Resource = aws_cloudfront_distribution.site.arn
      }
    ]
  })
}

# --- Outputs ----------------------------------------------------------------

output "acm_validation_records" {
  description = "STEP 1 — create these CNAMEs at the registrar; apply waits on them"
  value = [
    for dvo in aws_acm_certificate.site.domain_validation_options : {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  ]
}

output "cloudfront_domain" {
  description = "STEP 2 — point apex (ALIAS/flattened CNAME) and www (CNAME) here"
  value       = aws_cloudfront_distribution.site.domain_name
}

output "bucket_name" {
  value = aws_s3_bucket.site.bucket
}

output "cloudfront_distribution_id" {
  description = "Set as GitHub repo variable CLOUDFRONT_DISTRIBUTION_ID"
  value       = aws_cloudfront_distribution.site.id
}

output "deploy_role_arn" {
  description = "Set as GitHub repo variable AWS_ROLE_ARN"
  value       = aws_iam_role.deploy.arn
}
