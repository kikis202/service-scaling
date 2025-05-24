import json
import argparse
from datetime import datetime, timedelta

from elasticsearch import Elasticsearch
from elasticsearch.helpers import scan

# Map service names to their corresponding operations
OPERATION_MAP = {
    "ioService": "POST /simulate-io",
    "cpuService": "POST /fibonacci",
    "echoService": "POST /echo",
}

ES_HOST = "localhost"
ES_PORT = 9200
ES_INDEX = "jaeger-span-*"
LOOKBACK_HOURS = 6


def fetch_spans(es, service, operation):
    """Fetch all spans for service and operation in the last LOOKBACK_HOURS, drop zero-duration."""
    now = datetime.now()
    start = now - timedelta(hours=LOOKBACK_HOURS)
    start_us = int(start.timestamp() * 1_000_000)
    end_us = int(now.timestamp() * 1_000_000)

    query = {
        "query": {"bool": {"must": [
            {"range": {"startTime": {"gte": start_us, "lte": end_us}}},
            {"term": {"process.serviceName": service}},
            {"term": {"operationName": operation}},
        ]}},
        "sort": [{"startTime": {"order": "asc"}}]
    }

    spans = []
    for hit in scan(es, index=ES_INDEX, query=query, size=1000):
        src = hit["_source"]
        if src.get("duration", 0) > 0:
            spans.append(src)
    return spans


def build_traces(spans):
    """Group spans into traces and compute trace durations."""
    traces = {}
    for span in spans:
        tid = span.get("traceID")
        start = span.get("startTime", 0)
        dur = span.get("duration", 0)

        if tid not in traces:
            traces[tid] = {"trace_id": tid, "min_start": start, "max_end": start + dur, "span_count": 0}
        t = traces[tid]
        t["min_start"] = min(t["min_start"], start)
        t["max_end"] = max(t["max_end"], start + dur)
        t["span_count"] += 1

    output = []
    for t in traces.values():
        dur_us = t["max_end"] - t["min_start"]
        output.append({
            "trace_id": t["trace_id"],
            "span_count": t["span_count"],
            "duration_us": dur_us,
            "duration_ms": dur_us / 1000,
        })
    return output


def sanitize_operation(op):
    # Replace spaces and slashes for filename
    return op.replace("/", "_").replace(" ", "_")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--service", required=True, choices=OPERATION_MAP.keys())
    parser.add_argument("--path", help="Path to write JSON output (optional)")
    args = parser.parse_args()

    service = args.service
    operation = OPERATION_MAP[service]

    es = Elasticsearch([f"http://{ES_HOST}:{ES_PORT}"])
    if not es.ping():
        print(f"ERROR: Cannot connect to Elasticsearch at {ES_HOST}:{ES_PORT}")
        return

    spans = fetch_spans(es, service, operation)
    traces = build_traces(spans)

    # default filename if no path provided
    if args.path:
        out_path = args.path
    else:
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        count = len(spans)
        op_s = sanitize_operation(operation)
        filename = f"{service}_{op_s}_{LOOKBACK_HOURS}h_ALL{count}_{ts}.json"
        out_path = f"../monitoring/k6/results/curent/{filename}"

    result = {
        "extraction_info": {
            "service": service,
            "operation": operation,
            "lookback_hours": LOOKBACK_HOURS,
            "extraction_time": datetime.now().isoformat(),
            "total_spans": len(spans),
            "total_traces": len(traces),
        },
        "spans": spans,
        "traces": traces,
    }

    with open(out_path, "w") as f:
        json.dump(result, f, indent=2)

    print(f"Exported {len(spans)} spans and {len(traces)} traces to {out_path}")


if __name__ == "__main__":
    main()
