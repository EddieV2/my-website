# ---------------------------------------------------------------------------
# Athena over the CloudFront access logs.
#
# The logs are parquet, written by CloudWatch's vended-logs delivery. Nothing
# reads them by default -- this makes them queryable as a table so the actual
# questions ("who came, from where, which page, did they bounce") have an
# answer that is one SQL statement rather than a download and a script.
#
# No partitions: CloudFront writes every object into one flat prefix and puts
# the date-hour in the *filename*, not a directory, so there is nothing to
# partition on. At ~7KB per 5-minute object with a 90-day expiry the whole
# table stays in the low hundreds of MB, and Athena bills a 10MB minimum per
# query regardless -- so a full scan here costs a fraction of a cent.
#
# Column names come from the parquet schema itself, which snake-cases the
# delivery's record_fields: "cs(Referer)" is written as cs_Referer. Glue
# lowercases identifiers and Athena matches parquet columns case-insensitively.
# ---------------------------------------------------------------------------

resource "aws_glue_catalog_database" "analytics" {
  name        = "evsite_analytics"
  description = "CloudFront access logs for evartanessian.dev"
}

resource "aws_glue_catalog_table" "cf_logs" {
  name          = "cloudfront_logs"
  database_name = aws_glue_catalog_database.analytics.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    classification        = "parquet"
    "parquet.compression" = "SNAPPY"
    EXTERNAL              = "TRUE"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.logs.bucket}/AWSLogs/${data.aws_caller_identity.logs.account_id}/CloudFront/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
    }

    # Every field is delivered as a string, including the numeric ones -- cast
    # at query time rather than lying about the type here.
    dynamic "columns" {
      for_each = [
        "date", "time", "timestamp_ms", "c_ip", "asn", "c_country",
        "cs_uri_stem", "cs_uri_query", "cs_referer", "cs_user_agent",
        "sc_status", "sc_bytes", "time_taken", "time_to_first_byte",
        "x_edge_location", "x_edge_result_type", "x_edge_detailed_result_type",
        "cs_protocol", "cs_protocol_version", "x_host_header",
      ]
      content {
        name = columns.value
        type = "string"
      }
    }
  }
}

# Results land in the same bucket under a prefix the lifecycle rule already
# expires after 7 days -- they are derived data, not worth keeping.
resource "aws_athena_workgroup" "analytics" {
  name = "evsite-analytics"

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = false

    result_configuration {
      output_location = "s3://${aws_s3_bucket.logs.bucket}/athena-results/"

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }
}

output "athena_workgroup" {
  description = "Athena workgroup for querying access logs"
  value       = aws_athena_workgroup.analytics.name
}

output "athena_table" {
  description = "Fully-qualified table name for access-log queries"
  value       = "${aws_glue_catalog_database.analytics.name}.${aws_glue_catalog_table.cf_logs.name}"
}
