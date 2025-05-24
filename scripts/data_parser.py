import json
import argparse
import numpy as np
import pandas as pd
import numpy as np
import glob
import os
from datetime import datetime
import sys


def parse_prometheus(path):
    data = json.load(open(path))
    if data.get('status') != 'success':
        return None
    rows = []
    for result in data['data']['result']:
        labels = result.get('metric', {})
        for ts, val in result.get('values', []):
            rows.append({
                'timestamp': datetime.fromtimestamp(float(ts)),
                'value': None if val == 'NaN' else float(val),
                **labels
            })
    return pd.DataFrame(rows)


def parse_jaeger_api(path):
    data = json.load(open(path))
    traces, spans = [], []
    for trace in data.get('data', []):
        tid = trace.get('traceID')
        spans_list = trace.get('spans', [])
        if not spans_list:
            continue
        starts = [s.get('startTime',0) for s in spans_list]
        ends = [s.get('startTime',0)+s.get('duration',0) for s in spans_list]
        traces.append({
            'trace_id': tid,
            'span_count': len(spans_list),
            'trace_duration_ms': (max(ends)-min(starts))/1000,
            'start_time': datetime.fromtimestamp(min(starts)/1e6)
        })
        for s in spans_list:
            spans.append({
                'trace_id': tid,
                'span_id': s.get('spanID'),
                'operation': s.get('operationName'),
                'start_time': datetime.fromtimestamp(s.get('startTime',0)/1e6),
                'duration_ms': s.get('duration',0)/1000
            })
    return {'traces': pd.DataFrame(traces), 'spans': pd.DataFrame(spans)}


def parse_k6(path):
    data = json.load(open(path))
    checks, metrics = [], []
    for name, chk in data.get('root_group',{}).get('checks',{}).items():
        total = chk.get('passes',0)+chk.get('fails',0)
        checks.append({
            'check': name,
            'passes': chk.get('passes',0),
            'fails': chk.get('fails',0),
            'rate': chk.get('passes',0)/total if total else None
        })
    for m, info in data.get('metrics',{}).items():
        if isinstance(info,dict) and info.get('min') is not None:
            metrics.append({
                'metric': m,
                'min': info.get('min'),
                'avg': info.get('avg'),
                'max': info.get('max'),
                'p95': info.get('p(95)'),
                'p99': info.get('p(99)'),
                'p9999': info.get('p(99.99)')
            })
    return {'checks': pd.DataFrame(checks), 'metrics': pd.DataFrame(metrics)}


def detect_and_parse(path):
    data = json.load(open(path))
    name = os.path.splitext(os.path.basename(path))[0]
    # Prometheus JSON
    if data.get('status') and isinstance(data.get('data',{}).get('result'),list):
        df = parse_prometheus(path)
        return {f'prometheus_{name}':df} if df is not None and not df.empty else {}
    # K6 JSON
    if 'metrics' in data or 'root_group' in data:
        parsed = parse_k6(path)
        out={}
        if not parsed['checks'].empty:
            out[f'k6_checks_{name}']=parsed['checks']
        if not parsed['metrics'].empty:
            out[f'k6_metrics_{name}']=parsed['metrics']
        return out
    # Jaeger API JSON
    if isinstance(data.get('data'),list):
        parsed = parse_jaeger_api(path)
        out={}
        if not parsed['traces'].empty:
            out[f'jaeger_traces_{name}']=parsed['traces']
        if not parsed['spans'].empty:
            out[f'jaeger_spans_{name}']=parsed['spans']
        return out
    # Minimal Jaeger export
    if 'spans' in data and 'traces' in data:
        return {
            f'jaeger_traces_{name}':pd.DataFrame(data['traces']),
            f'jaeger_spans_{name}':pd.DataFrame(data['spans'])
        }
    return {}


def create_summary(datasets):
    stats = []
    # First, overall metric summaries
    for sheet, df in datasets.items():
        # detect main numeric column
        for col in ['value','trace_duration_ms','duration_ms','rate','avg','p9999']:
            if col in df.columns:
                # detect unit
                unit = ''
                if sheet.startswith('prometheus_') and '_pct_' in sheet:
                    unit = '%'
                elif sheet.startswith('prometheus_') and 'memory' in sheet:
                    unit = 'bytes'
                elif sheet.startswith('jaeger_'):
                    unit = 'ms'
                elif sheet.startswith('k6_metrics_'):
                    unit = 'ms'
                # append overall summary
                stats.append({
                    'sheet': sheet,
                    'count': len(df),
                    'mean': df[col].mean(),
                    'std': df[col].std(),
                    'p95': df[col].quantile(0.95),
                    'p99': df[col].quantile(0.99),
                    'p99.99': df[col].quantile(0.9999),
                    'unit': unit
                })
                break
    for sheet, df in datasets.items():
        if 'pod' in df.columns and 'value' in df.columns:
            # compute Gini across pod means
            pod_means = df.groupby('pod')['value'].mean().values
            if len(pod_means) > 1:
                # Gini coefficient
                sorted_vals = np.sort(pod_means)
                n = len(sorted_vals)
                index = np.arange(1, n+1)
                gini = (2 * np.sum(index * sorted_vals) / (n * np.sum(sorted_vals))) - (n + 1) / n
            else:
                gini = 0.0
            unit = ''
            if sheet.startswith('prometheus_') and '_pct_' in sheet:
                unit = '%'
            elif sheet.startswith('prometheus_') and 'memory' in sheet:
                unit = 'bytes'
            stats.append({
                'sheet': f"{sheet}_pods_gini",
                'count': len(pod_means),
                'mean': gini,
                'std': None,
                'p95': None,
                'p99': None,
                'p99.99': None,
                'unit': '%'
            })
            for pod, group in df.groupby('pod'):
                stats.append({
                    'sheet': f"{sheet}_pod_{pod}",
                    'count': len(group),
                    'mean': group['value'].mean(),
                    'std': group['value'].std(),
                    'p95': group['value'].quantile(0.95),
                    'p99': group['value'].quantile(0.99),
                    'p99.99': group['value'].quantile(0.9999),
                    'unit': unit
                })
    return pd.DataFrame(stats)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--service", required=True, choices=["ioService", "cpuService", "echoService"])
    parser.add_argument("--input", help="Path to data folder")
    parser.add_argument("--output", help="Path to write XLSX output (optional)")
    args = parser.parse_args()

    folder=args.input if args.input else '../monitoring/k6/results/curent'
    out=args.output if args.output else f"../monitoring/k6/results/{args.service if args.service else 'done'}/summary_{datetime.now():%Y%m%d_%H%M%S}.xlsx"
    datasets={}
    for path in glob.glob(os.path.join(folder,'*.json')):
        datasets.update(detect_and_parse(path))
    if not datasets:
        print("No JSON datasets found.")
        return
    summary=create_summary(datasets)

    os.makedirs(os.path.dirname(out), exist_ok=True)
    with pd.ExcelWriter(out,engine='openpyxl') as writer:
        if not summary.empty:
            summary.to_excel(writer,sheet_name='Summary',index=False)
        for name,df in datasets.items():
            df.to_excel(writer,sheet_name=name[:31],index=False)
    print(f"Written Excel file: {out}")

if __name__=='__main__':
    main()
