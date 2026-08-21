"""Hourly status publisher: queries CloudWatch for RUM, synthetic, and
CloudFront edge metrics, computes SLO status + error budget, and writes
status.json into the site bucket (short-TTL cached; the /observability page
fetches it same-origin).
"""

import datetime as dt
import json
import os

import boto3

cw = boto3.client("cloudwatch", region_name="us-east-1")
s3 = boto3.client("s3")
ssm = boto3.client("ssm")

BUCKET = os.environ["BUCKET"]
# Read at cold start via SSM: a direct Terraform env reference would cycle
# (distribution depends on the RUM function URL, which depends on the lambdas).
DISTRIBUTION_ID = ssm.get_parameter(Name=os.environ["DISTRIBUTION_PARAM"])["Parameter"]["Value"]

AVAILABILITY_TARGET = 99.9      # % over 30 days (synthetic)

# The SLO measures the service as launched. Before this date the domain was
# deliberately unpointed while the site still carried claims that hadn't been
# verified, so probe failures then record a config state that was chosen, not
# unplanned downtime — the thing an error budget exists to measure. The window
# is floored here and the start date is published in status.json so the page
# states it rather than quietly applying it.
SERVICE_START = dt.datetime(2026, 8, 6, tzinfo=dt.timezone.utc)
LCP_TARGET_MS = 1500            # p75 (RUM)

# A p75 needs enough sessions to actually be a 75th percentile. Below this the
# tile still publishes the measurement, but withholds the pass/fail verdict: at
# single-digit sample counts one cold cache or one bad mobile session scores the
# SLO, which measures the sample rather than the service. Published as a field
# so the page can state the reason instead of quietly suppressing a breach --
# same reasoning as SERVICE_START.
LCP_MIN_SAMPLES = 100


def _metric(namespace, name, stat, start, end, period, dimensions=None):
    resp = cw.get_metric_data(
        MetricDataQueries=[{
            "Id": "m",
            "MetricStat": {
                "Metric": {
                    "Namespace": namespace,
                    "MetricName": name,
                    "Dimensions": dimensions or [],
                },
                "Period": period,
                "Stat": stat,
            },
        }],
        StartTime=start,
        EndTime=end,
        ScanBy="TimestampAscending",
    )
    r = resp["MetricDataResults"][0]
    return list(zip(r["Timestamps"], r["Values"]))


def handler(_event, _context):
    now = dt.datetime.now(dt.timezone.utc)
    d30, d7, h24 = now - dt.timedelta(days=30), now - dt.timedelta(days=7), now - dt.timedelta(hours=24)
    # Never reach back past launch — see SERVICE_START.
    d30 = max(d30, SERVICE_START)
    window_days = max(1, (now - d30).days)
    cf_dims = [
        {"Name": "DistributionId", "Value": DISTRIBUTION_ID},
        {"Name": "Region", "Value": "Global"},
    ]

    # Availability: average of 0/1 checks. Daily buckets for the sparkline.
    avail_daily = _metric("EvSite/Synthetics", "Availability", "Average", d30, now, 86400)
    avail_all = _metric("EvSite/Synthetics", "Availability", "Average", d30, now, 31 * 86400)
    availability_pct = round(avail_all[0][1] * 100, 3) if avail_all else None

    budget_remaining = None
    if availability_pct is not None:
        allowed = 100.0 - AVAILABILITY_TARGET
        used = max(0.0, 100.0 - availability_pct)
        budget_remaining = round(max(0.0, (1 - used / allowed)) * 100, 1)

    probe_hourly = _metric("EvSite/Synthetics", "ProbeLatency", "p75", h24, now, 3600)
    probe_p75 = _metric("EvSite/Synthetics", "ProbeLatency", "p75", h24, now, 86400)

    def single(namespace, name, stat, start, period):
        rows = _metric(namespace, name, stat, start, now, period)
        return round(rows[-1][1], 1) if rows else None

    vitals = {
        "lcp_p75_ms": single("EvSite/RUM", "LCP", "p75", d7, 7 * 86400),
        "cls_p75": single("EvSite/RUM", "CLS", "p75", d7, 7 * 86400),
        "inp_p75_ms": single("EvSite/RUM", "INP", "p75", d7, 7 * 86400),
        "ttfb_p75_ms": single("EvSite/RUM", "TTFB", "p75", d7, 7 * 86400),
        "samples_7d": single("EvSite/RUM", "PageView", "SampleCount", d7, 7 * 86400),
    }

    requests_24h = single("AWS/CloudFront", "Requests", "Sum", h24, 86400)
    error_rate = single("AWS/CloudFront", "TotalErrorRate", "Average", h24, 86400)

    status = {
        "generated_at": now.isoformat(timespec="seconds"),
        "slo": {
            "availability": {
                "target_pct": AVAILABILITY_TARGET,
                "actual_pct": availability_pct,
                "budget_remaining_pct": budget_remaining,
                "window_days": window_days,
                "since": d30.date().isoformat(),
            },
            "lcp": {
                "target_p75_ms": LCP_TARGET_MS,
                "actual_p75_ms": vitals["lcp_p75_ms"],
                "window_days": 7,
                "samples": vitals["samples_7d"],
                "min_samples": LCP_MIN_SAMPLES,
                "sufficient_samples": (vitals["samples_7d"] or 0) >= LCP_MIN_SAMPLES,
            },
        },
        "vitals": vitals,
        "traffic": {"requests_24h": requests_24h, "error_rate_24h_pct": error_rate},
        "synthetics": {"probe_p75_ms_24h": probe_p75[0][1] if probe_p75 else None},
        "series": {
            "availability_30d": [
                {"t": t.strftime("%m-%d"), "pct": round(v * 100, 2)} for t, v in avail_daily
            ],
            "probe_latency_24h": [
                {"t": t.strftime("%H:%M"), "ms": round(v, 1)} for t, v in probe_hourly
            ],
        },
    }

    s3.put_object(
        Bucket=BUCKET,
        Key="status.json",
        Body=json.dumps(status).encode(),
        ContentType="application/json",
        CacheControl="public, max-age=300",
    )
    return {"ok": True, "availability": availability_pct}
