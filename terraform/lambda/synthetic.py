"""Synthetic availability probe, every 5 minutes via EventBridge.

Checks the homepage and one case-study page over HTTPS from outside the CDN's
own cache view (cache-busting query), records availability and latency as
CloudWatch EMF metrics. This feeds the site's 99.9%/30d availability SLO.
"""

import json
import os
import time
import urllib.request

import boto3

# Probe the distribution directly rather than the vanity domain: this measures
# whether the service is serving, which is what the availability SLO is about.
# DNS/registrar state is a separate failure domain and would otherwise show up
# here as an origin outage that never happened.
ORIGIN = boto3.client("ssm").get_parameter(
    Name=os.environ["ORIGIN_PARAM"]
)["Parameter"]["Value"].rstrip("/")
TARGETS = [f"{ORIGIN}/", f"{ORIGIN}/work/otel-collector.html"]
TIMEOUT_S = 10


def handler(_event, _context):
    for url in TARGETS:
        ok, elapsed_ms = 0, TIMEOUT_S * 1000
        started = time.monotonic()
        try:
            req = urllib.request.Request(
                f"{url}?probe={int(time.time())}",
                headers={"User-Agent": "ev-site-synthetic/1.0"},
            )
            with urllib.request.urlopen(req, timeout=TIMEOUT_S) as resp:
                elapsed_ms = (time.monotonic() - started) * 1000
                ok = 1 if resp.status == 200 else 0
        except Exception:  # noqa: BLE001 — any failure is an availability miss
            elapsed_ms = (time.monotonic() - started) * 1000
            ok = 0

        print(json.dumps({
            "_aws": {
                "Timestamp": int(time.time() * 1000),
                "CloudWatchMetrics": [{
                    "Namespace": "EvSite/Synthetics",
                    "Dimensions": [[]],
                    "Metrics": [
                        {"Name": "Availability", "Unit": "None"},
                        {"Name": "ProbeLatency", "Unit": "Milliseconds"},
                    ],
                }],
            },
            "Availability": ok,
            "ProbeLatency": round(elapsed_ms, 1),
            "target": url,
        }))
    return {"ok": True}
