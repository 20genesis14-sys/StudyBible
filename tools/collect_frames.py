#!/usr/bin/env python3
"""Collect Flutter Frame timeline events from the VM service.
Usage: collect_frames.py <ws_url> <duration_sec> <out.txt>
Pairs b/e 'Frame' events by frame id per thread; reports per-thread frame
durations (UI build / raster) and frame-to-frame intervals (jank).
"""
import json, sys, time, websocket
from collections import defaultdict

ws_url, dur, out = sys.argv[1], float(sys.argv[2]), sys.argv[3]
ws = websocket.create_connection(ws_url, timeout=dur + 10)
mid = 0
def call(method, params=None):
    global mid
    mid += 1
    ws.send(json.dumps({"jsonrpc": "2.0", "id": mid, "method": method, "params": params or {}}))
    while True:
        m = json.loads(ws.recv())
        if m.get("id") == mid:
            return m

call("streamListen", {"streamId": "Timeline"})
deadline = time.time() + dur
opens = defaultdict(list)   # (tid,fid) -> ts
durs = defaultdict(list)    # tid -> [frame duration ms]
starts = defaultdict(list)  # tid -> [frame start ts]
ws.settimeout(1.0)
while time.time() < deadline:
    try:
        m = json.loads(ws.recv())
    except websocket.WebSocketTimeoutException:
        continue
    if m.get("method") != "streamNotify":
        continue
    for tev in m["params"]["event"].get("timelineEvents", []):
        if tev.get("name") != "Frame":
            continue
        key = (tev["tid"], tev.get("id"))
        if tev["ph"] == "b":
            opens[key].append(tev["ts"])
            starts[tev["tid"]].append(tev["ts"])
        elif tev["ph"] == "e" and opens.get(key):
            b = opens[key].pop(0)
            durs[tev["tid"]].append((tev["ts"] - b) / 1000.0)
ws.close()

def pct(v, p):
    v = sorted(v)
    return v[min(len(v) - 1, int(len(v) * p))] if v else 0.0

lines = []
for tid, ds in sorted(durs.items(), key=lambda kv: -len(kv[1])):
    iv = [b - a for a, b in zip(starts[tid], starts[tid][1:])]
    iv_ms = [x / 1000.0 for x in iv]
    j16 = sum(1 for x in iv_ms if x > 20.0)
    j8 = sum(1 for x in iv_ms if x > 12.0)
    lines.append(
        f"tid={tid} frames={len(ds)} dur_ms p50={pct(ds,.5):.1f} p90={pct(ds,.9):.1f} "
        f"max={max(ds):.1f} | interval_ms p50={pct(iv_ms,.5):.1f} p90={pct(iv_ms,.9):.1f} "
        f"max={max(iv_ms) if iv_ms else 0:.1f} | >20ms={j16} >12ms={j8}"
    )
with open(out, "w") as f:
    f.write("\n".join(lines) + "\n")
print("\n".join(lines))
