# ---------------------------------------------------------------------------
# Observability: RUM ingest (CloudFront /rum → Lambda Function URL → CloudWatch
# EMF), 5-minute synthetic probes, and an hourly publisher that writes
# status.json for the public /observability page. No servers, no database;
# well inside the Lambda/EventBridge free tiers.
# ---------------------------------------------------------------------------

resource "random_password" "origin_secret" {
  length  = 32
  special = false
}

# --- Shared bits ------------------------------------------------------------

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_policy" "lambda_logs" {
  name = "ev-site-lambda-logs"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "arn:aws:logs:*:*:*"
    }]
  })
}

locals {
  lambdas = {
    rum       = { file = "rum_ingest.py", handler = "rum_ingest.handler", timeout = 3 }
    synthetic = { file = "synthetic.py", handler = "synthetic.handler", timeout = 30 }
    publisher = { file = "publisher.py", handler = "publisher.handler", timeout = 60 }
  }
}

data "archive_file" "lambda" {
  for_each    = local.lambdas
  type        = "zip"
  source_file = "${path.module}/lambda/${each.value.file}"
  output_path = "${path.module}/.build/${each.key}.zip"
}

resource "aws_iam_role" "lambda" {
  for_each           = local.lambdas
  name               = "ev-site-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  for_each   = local.lambdas
  role       = aws_iam_role.lambda[each.key].name
  policy_arn = aws_iam_policy.lambda_logs.arn
}

resource "aws_lambda_function" "fn" {
  for_each         = local.lambdas
  function_name    = "ev-site-${each.key}"
  role             = aws_iam_role.lambda[each.key].arn
  runtime          = "python3.13"
  handler          = each.value.handler
  timeout          = each.value.timeout
  memory_size      = 128
  filename         = data.archive_file.lambda[each.key].output_path
  source_code_hash = data.archive_file.lambda[each.key].output_base64sha256

  environment {
    variables = each.key == "rum" ? {
      ORIGIN_SECRET = random_password.origin_secret.result
      } : each.key == "publisher" ? {
      # Distribution id comes from SSM at runtime — a direct reference here
      # would create a cycle (distribution → rum function URL → lambdas).
      BUCKET             = aws_s3_bucket.site.bucket
      DISTRIBUTION_PARAM = "/ev-site/distribution-id"
      } : {}
  }
}

resource "aws_ssm_parameter" "distribution_id" {
  name  = "/ev-site/distribution-id"
  type  = "String"
  value = aws_cloudfront_distribution.site.id
}

# --- RUM ingest: Function URL fronted by the /rum CloudFront behavior --------

resource "aws_lambda_function_url" "rum" {
  function_name      = aws_lambda_function.fn["rum"].function_name
  authorization_type = "NONE" # gated by the X-Origin-Verify shared secret
}

# --- Publisher extras: read metrics, write status.json -----------------------

resource "aws_iam_role_policy" "publisher_extras" {
  name = "publish-status"
  role = aws_iam_role.lambda["publisher"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["cloudwatch:GetMetricData"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.site.arn}/status.json"
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = aws_ssm_parameter.distribution_id.arn
      }
    ]
  })
}

# --- Schedules ---------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "synthetic" {
  name                = "ev-site-synthetic-5m"
  schedule_expression = "rate(5 minutes)"
}

resource "aws_cloudwatch_event_rule" "publisher" {
  name                = "ev-site-publish-status-1h"
  schedule_expression = "rate(1 hour)"
}

resource "aws_cloudwatch_event_target" "synthetic" {
  rule = aws_cloudwatch_event_rule.synthetic.name
  arn  = aws_lambda_function.fn["synthetic"].arn
}

resource "aws_cloudwatch_event_target" "publisher" {
  rule = aws_cloudwatch_event_rule.publisher.name
  arn  = aws_lambda_function.fn["publisher"].arn
}

resource "aws_lambda_permission" "synthetic" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.fn["synthetic"].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.synthetic.arn
}

resource "aws_lambda_permission" "publisher" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.fn["publisher"].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.publisher.arn
}

output "rum_function_url" {
  value = aws_lambda_function_url.rum.function_url
}
