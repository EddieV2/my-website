"""RUM beacon ingest: validate a tiny Web-Vitals payload and emit CloudWatch
metrics via Embedded Metric Format (printed to stdout — no SDK calls, no
database). Reached only through the CloudFront /rum behavior, which attaches a
shared-secret header; direct Function-URL calls are rejected.

Privacy: nothing user-identifying is read or stored. No IPs, no IDs, no paths
beyond the page path itself (bounded), no logs of raw bodies on the happy path.
"""

import json
import os
import time

MAX_BODY = 1024

# The beacon has always sent the page path; it was parsed and then dropped, so
# "which page did they read" was unanswerable even though the data arrived
# here. It becomes a dimension now — but only for paths that actually exist.
# An unbounded dimension is a cost hazard rather than a privacy one: every
# distinct value becomes its own billed CloudWatch series, and this site takes
# scanner sweeps (1,966 requests in one hour, 63% of them 404s, 2026-09-12).
# An allowlist caps the blast radius at these six plus "other".
PAGES = frozenset({
    "/",
    "/observability.html",
    "/404.html",
    "/work/copywarden.html",
    "/work/fleet-automation.html",
    "/work/otel-collector.html",
})

BOUNDS = {  # metric: (min, max) — reject junk beacons
    "lcp": (0, 60_000),
    "cls": (0, 10),
    "inp": (0, 60_000),
    "ttfb": (0, 60_000),
}

# Soft per-container token bucket — good enough to blunt casual abuse.
_bucket = {"tokens": 60.0, "ts": time.monotonic()}


def _take_token() -> bool:
    now = time.monotonic()
    _bucket["tokens"] = min(60.0, _bucket["tokens"] + (now - _bucket["ts"]) * 1.0)
    _bucket["ts"] = now
    if _bucket["tokens"] < 1:
        return False
    _bucket["tokens"] -= 1
    return True


def handler(event, _context):
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    if headers.get("x-origin-verify") != os.environ["ORIGIN_SECRET"]:
        return {"statusCode": 403, "body": ""}
    if not _take_token():
        return {"statusCode": 429, "body": ""}

    body = event.get("body") or ""
    if len(body) > MAX_BODY:
        return {"statusCode": 413, "body": ""}
    try:
        data = json.loads(body)
    except (json.JSONDecodeError, TypeError):
        return {"statusCode": 400, "body": ""}
    if not isinstance(data, dict) or data.get("v") != 1:
        return {"statusCode": 400, "body": ""}

    metrics = {}
    for name, (lo, hi) in BOUNDS.items():
        value = data.get(name)
        if isinstance(value, (int, float)) and lo <= value <= hi and value > 0:
            metrics[name] = float(value)
    if not metrics:
        return {"statusCode": 400, "body": ""}

    raw_path = data.get("path")
    page = raw_path if isinstance(raw_path, str) and raw_path in PAGES else "other"

    # Two dimension sets: the empty one keeps the existing fleet-wide series
    # intact (the publisher and the SLO gate read those), and ["page"] adds the
    # per-page breakdown that makes bounce rate measurable.
    emf = {
        "_aws": {
            "Timestamp": int(time.time() * 1000),
            "CloudWatchMetrics": [
                {
                    "Namespace": "EvSite/RUM",
                    "Dimensions": [[], ["page"]],
                    "Metrics": [
                        {"Name": n.upper(), "Unit": "None" if n == "cls" else "Milliseconds"}
                        for n in metrics
                    ] + [{"Name": "PageView", "Unit": "Count"}],
                }
            ],
        },
        "page": page,
        "PageView": 1,
        **{n.upper(): v for n, v in metrics.items()},
    }
    print(json.dumps(emf))
    return {"statusCode": 202, "body": ""}
