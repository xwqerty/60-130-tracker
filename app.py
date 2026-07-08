#!/usr/bin/env python3
"""Simple browser app for the 60-130 tracker.

Runs a tiny local web server (standard library only) and opens a page that:
  - watches for the MHD adapter and shows when the car link is ready
  - shows live speed
  - arms a run only when you press the button (one run per press)

Usage:
  python3 app.py            # real car via MHD adapter
  python3 app.py --sim      # simulated car for testing

Then open http://localhost:8130 (opens automatically).
"""

import argparse
import json
import threading
import time
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import hsfz
import runlog
import speed

FALLBACK_HOSTS = ["192.168.16.254", "169.254.128.7"]
RANGES = {"60-130": (60.0, 130.0), "0-40": (0.0, 40.0), "30-100": (30.0, 100.0)}


class Engine(threading.Thread):
    """Background worker: finds the adapter, polls speed, times armed runs."""

    def __init__(self, sim=False, sim_speedup=1.0, log_dir="logs"):
        super().__init__(daemon=True)
        self.sim = sim
        self.sim_speedup = sim_speedup
        self.log_dir = log_dir
        self.lock = threading.Lock()

        self.connected = False
        self.detail = ""           # e.g. gateway IP / read mode
        self.mph = 0.0
        self.last_t = 0.0
        self.armed = False
        self.tracker = None
        self.results = []

    # -- called from the HTTP thread ------------------------------------

    def snapshot(self):
        with self.lock:
            recording = bool(self.tracker and self.tracker.state == runlog.RECORDING)
            elapsed = (self.last_t - self.tracker.t_start) if recording else None
            if not self.connected:
                status, phase = "Searching for MHD adapter…", "searching"
            elif not self.armed:
                status, phase = "Connected — ready to log", "ready"
            elif recording:
                status, phase = "Recording…", "recording"
            else:
                go = ("launch from a stop" if self.tracker.start_mph == 0
                      else f"cross {self.tracker.start_mph:g} mph")
                status, phase = f"Armed — {go} to start the clock", "armed"
            return {
                "connected": self.connected,
                "sim": self.sim,
                "detail": self.detail,
                "status": status,
                "phase": phase,
                "mph": round(self.mph, 1),
                "elapsed": round(elapsed, 2) if elapsed is not None else None,
                "results": list(reversed(self.results)),
            }

    def arm(self, range_key):
        start, end = RANGES.get(range_key, RANGES["60-130"])
        with self.lock:
            if not self.connected or self.armed:
                return False
            self.tracker = runlog.RunTracker(log_dir=self.log_dir,
                                             start_mph=start, end_mph=end)
            self.armed = True
            return True

    def cancel(self):
        with self.lock:
            if self.tracker:
                r = self.tracker.flush()   # save a partial if mid-run
                if r:
                    self._store(r)
            self.armed = False
            self.tracker = None

    # -- worker loop -----------------------------------------------------

    def _store(self, r):
        self.results.append({
            "when": r["when"].strftime("%H:%M:%S"),
            "range": r["range"],
            "complete": r["complete"],
            "total": round(r["total"], 2) if r["total"] else None,
            "split_labels": list(r["split_labels"]),
            "split1": round(r["split1"], 2) if r["split1"] else None,
            "split2": round(r["split2"], 2) if r["split2"] else None,
            "vmax": round(r["vmax_mph"], 1),
            "file": r["file"],
        })

    def _connect(self):
        if self.sim:
            return speed.SimSpeedSource(speedup=self.sim_speedup), None
        hosts = []
        found = hsfz.discover(timeout=1.5)
        if found:
            hosts = [found[0]]
        hosts += [h for h in FALLBACK_HOSTS if h not in hosts]
        for host in hosts:
            client = hsfz.HsfzClient(host, timeout=2.0)
            try:
                client.connect()
                src = speed.EnetSpeedSource(client)
                mode = src.start()
                with self.lock:
                    self.detail = f"{host} · {mode}"
                return src, client
            except Exception:
                client.close()
        return None, None

    def run(self):
        while True:
            try:
                source, client = self._connect()
            except Exception:
                source, client = None, None
            if not source:
                time.sleep(2.0)
                continue
            with self.lock:
                self.connected = True
                if self.sim:
                    self.detail = "simulator"
            try:
                while True:
                    t, kmh = source.read()
                    with self.lock:
                        self.mph = kmh / speed.KMH_PER_MPH
                        self.last_t = t
                        if self.armed and self.tracker:
                            r = self.tracker.add_sample(t, self.mph)
                            if r:
                                self._store(r)
                                self.armed = False   # one run per button press
                                self.tracker = None
            except Exception:
                pass  # lost the adapter; fall through and reconnect
            finally:
                with self.lock:
                    self.connected = False
                    self.armed = False
                    self.tracker = None
                if client:
                    client.close()


PAGE = """<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>60-130 Tracker</title>
<style>
  body { background:#111; color:#eee; font-family:-apple-system,Helvetica,sans-serif;
         display:flex; flex-direction:column; align-items:center; margin:0; padding:2rem 1rem; }
  h1 { font-size:1.2rem; font-weight:600; letter-spacing:.05em; color:#888; margin:0 0 1.5rem; }
  #status { display:flex; align-items:center; gap:.6rem; font-size:1.1rem; margin-bottom:.3rem; }
  #dot { width:.8rem; height:.8rem; border-radius:50%; background:#e6a817; }
  .ready #dot { background:#2ecc71; } .armed #dot, .recording #dot { background:#e74c3c; }
  #detail { color:#666; font-size:.8rem; height:1rem; margin-bottom:1rem; }
  #mph { font-size:6rem; font-weight:700; font-variant-numeric:tabular-nums; line-height:1; }
  #mphlabel { color:#666; margin-bottom:1.5rem; }
  #elapsed { font-size:2rem; color:#e74c3c; font-variant-numeric:tabular-nums;
             height:2.5rem; margin-bottom:1rem; }
  select { font-size:1.1rem; padding:.5rem; background:#222; color:#eee;
           border:1px solid #444; border-radius:.5rem; margin-bottom:1rem; }
  button { font-size:1.6rem; font-weight:700; padding:1.2rem 3.5rem; border:none;
           border-radius:1rem; background:#2ecc71; color:#08301c; cursor:pointer; }
  button:disabled { background:#333; color:#666; cursor:default; }
  button.cancel { background:#e74c3c; color:#3d0c07; }
  #runs { width:100%; max-width:30rem; margin-top:2rem; }
  .run { background:#1b1b1b; border:1px solid #2a2a2a; border-radius:.7rem;
         padding:.8rem 1rem; margin-bottom:.6rem; }
  .run .big { font-size:1.5rem; font-weight:700; }
  .run .sub { color:#888; font-size:.85rem; margin-top:.2rem; }
  .partial .big { color:#e6a817; }
</style></head><body>
<h1>60&ndash;130 TRACKER</h1>
<div id="status"><span id="dot"></span><span id="statustext">Starting&hellip;</span></div>
<div id="detail"></div>
<div id="mph">--</div>
<div id="mphlabel">mph</div>
<div id="elapsed"></div>
<select id="range">
  <option value="60-130">60&ndash;130 mph</option>
  <option value="0-40">0&ndash;40 mph (test)</option>
  <option value="30-100">30&ndash;100 mph</option>
</select>
<button id="go" disabled>START LOG</button>
<div id="runs"></div>
<script>
const $ = id => document.getElementById(id);
let phase = "searching";
$("go").onclick = () => {
  const url = (phase === "ready")
    ? "/start?range=" + encodeURIComponent($("range").value) : "/cancel";
  fetch(url, {method: "POST"});
};
function render(s) {
  phase = s.phase;
  document.body.className = s.phase;
  $("statustext").textContent = s.status;
  $("detail").textContent = s.detail ? (s.sim ? "SIMULATOR" : s.detail) : "";
  $("mph").textContent = s.connected ? s.mph.toFixed(1) : "--";
  $("elapsed").textContent = s.elapsed != null ? "+" + s.elapsed.toFixed(2) + " s" : "";
  const go = $("go");
  go.disabled = !s.connected;
  go.textContent = (s.phase === "armed" || s.phase === "recording") ? "CANCEL" : "START LOG";
  go.className = (s.phase === "armed" || s.phase === "recording") ? "cancel" : "";
  $("range").style.visibility = (s.phase === "ready" || s.phase === "searching") ? "visible" : "hidden";
  $("runs").innerHTML = s.results.map(r => {
    const cls = r.complete ? "run" : "run partial";
    const head = r.complete ? r.range + ": " + r.total.toFixed(2) + " s"
                            : r.range + ": lifted early";
    const bits = [];
    if (r.split1 != null) bits.push(r.split_labels[0] + " " + r.split1.toFixed(2) + "s");
    if (r.split2 != null) bits.push(r.split_labels[1] + " " + r.split2.toFixed(2) + "s");
    bits.push("vmax " + r.vmax.toFixed(1) + " mph");
    return '<div class="' + cls + '"><div class="big">' + head + '</div>' +
           '<div class="sub">' + bits.join(" &middot; ") + " &middot; " + r.when + "</div></div>";
  }).join("");
}
setInterval(() => fetch("/state").then(r => r.json()).then(render).catch(() => {}), 150);
</script></body></html>"""


def make_handler(engine):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _json(self, obj, code=200):
            body = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path == "/state":
                self._json(engine.snapshot())
            elif self.path == "/" or self.path.startswith("/index"):
                body = PAGE.encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            else:
                self.send_error(404)

        def do_POST(self):
            if self.path.startswith("/start"):
                range_key = "60-130"
                if "range=" in self.path:
                    range_key = self.path.split("range=", 1)[1]
                self._json({"ok": engine.arm(range_key)})
            elif self.path == "/cancel":
                engine.cancel()
                self._json({"ok": True})
            else:
                self.send_error(404)

    return Handler


def main():
    p = argparse.ArgumentParser(description="Browser app for the 60-130 tracker")
    p.add_argument("--port", type=int, default=8130)
    p.add_argument("--log-dir", default="logs")
    p.add_argument("--sim", action="store_true", help="simulated car, no adapter needed")
    p.add_argument("--sim-speedup", type=float, default=1.0)
    p.add_argument("--no-browser", action="store_true", help="don't auto-open the page")
    args = p.parse_args()

    engine = Engine(sim=args.sim, sim_speedup=args.sim_speedup, log_dir=args.log_dir)
    engine.start()

    server = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(engine))
    url = f"http://localhost:{args.port}"
    print(f"60-130 Tracker running at {url}  (Ctrl+C to quit)")
    if not args.no_browser:
        threading.Timer(0.5, webbrowser.open, [url]).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nBye.")


if __name__ == "__main__":
    main()
