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

    emf = {
        "_aws": {
            "Timestamp": int(time.time() * 1000),
            "CloudWatchMetrics": [
                {
                    "Namespace": "EvSite/RUM",
                    "Dimensions": [[]],
                    "Metrics": [
                        {"Name": n.upper(), "Unit": "None" if n == "cls" else "Milliseconds"}
                        for n in metrics
                    ] + [{"Name": "PageView", "Unit": "Count"}],
                }
            ],
        },
        "PageView": 1,
        **{n.upper(): v for n, v in metrics.items()},
    }
    print(json.dumps(emf))
    return {"statusCode": 202, "body": ""}
