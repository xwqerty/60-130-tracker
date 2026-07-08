"""60-130 run detection, timing, and CSV logging.

State machine fed with (timestamp, mph) samples:

  ARMED      speed below 60. Keeps a short pre-roll buffer so the log
             shows the launch, not just the moment of crossing.
  RECORDING  entered the instant a sample crosses 60 mph. The exact
             crossing time is linearly interpolated between the sample
             below and above the threshold, so timing accuracy is much
             finer than the polling interval. Same at 100 and 130.
  COOLDOWN   after a finished/aborted run; re-arms once speed < 55.

A run completes at 130 mph, or is saved as partial if you lift early
(speed falling well below the peak before reaching 130).
"""

import collections
import csv
import os
from datetime import datetime

KMH_PER_MPH = 1.609344

START_MPH = 60.0
SPLIT_MPH = 100.0
END_MPH = 130.0
REARM_MPH = 55.0
ABORT_DROP_MPH = 4.0    # lift detection: this far below peak = run over
PREROLL_S = 3.0

ARMED, RECORDING, COOLDOWN = "ARMED", "RECORDING", "COOLDOWN"


def _interp_time(t0, v0, t1, v1, threshold):
    """Time at which speed crossed `threshold` between two samples."""
    if v1 == v0:
        return t1
    return t0 + (threshold - v0) / (v1 - v0) * (t1 - t0)


class RunTracker:
    def __init__(self, log_dir="logs"):
        self.log_dir = log_dir
        self.state = ARMED
        self.prev = None                    # (t, mph)
        self.preroll = collections.deque()  # samples before the 60 crossing
        self.samples = []                   # samples during the run
        self.t60 = self.t100 = self.t130 = None
        self.vmax = 0.0
        self.runs_completed = 0

    # ------------------------------------------------------------------

    def add_sample(self, t, mph):
        """Feed one sample. Returns a result dict when a run just ended."""
        result = None
        prev = self.prev
        self.prev = (t, mph)

        if self.state == ARMED:
            self.preroll.append((t, mph))
            while self.preroll and t - self.preroll[0][0] > PREROLL_S:
                self.preroll.popleft()
            if prev and prev[1] < START_MPH <= mph:
                self._start_run(prev, (t, mph))

        elif self.state == RECORDING:
            self.samples.append((t, mph))
            self.vmax = max(self.vmax, mph)
            if prev and prev[1] < SPLIT_MPH <= mph:
                self.t100 = _interp_time(*prev, t, mph, SPLIT_MPH)
            if prev and prev[1] < END_MPH <= mph:
                self.t130 = _interp_time(*prev, t, mph, END_MPH)
                result = self._finish(complete=True)
            elif mph < self.vmax - ABORT_DROP_MPH:
                result = self._finish(complete=False)

        elif self.state == COOLDOWN:
            if mph < REARM_MPH:
                self.state = ARMED
                self.preroll.clear()

        return result

    def flush(self):
        """Save whatever is in progress (e.g. on Ctrl+C mid-run)."""
        if self.state == RECORDING and self.samples:
            return self._finish(complete=False)
        return None

    # ------------------------------------------------------------------

    def _start_run(self, below, above):
        self.state = RECORDING
        self.t60 = _interp_time(*below, *above, START_MPH)
        self.t100 = self.t130 = None
        self.vmax = above[1]
        self.samples = list(self.preroll) + [above]

    def _finish(self, complete):
        elapsed_60_130 = self.t130 - self.t60 if complete else None
        elapsed_60_100 = self.t100 - self.t60 if self.t100 else None
        elapsed_100_130 = self.t130 - self.t100 if (complete and self.t100) else None

        # effective sample rate during the run proper
        run = [s for s in self.samples if s[0] >= self.t60]
        rate = (len(run) - 1) / (run[-1][0] - run[0][0]) if len(run) > 1 else 0.0

        result = {
            "when": datetime.now(),
            "complete": complete,
            "60-130": elapsed_60_130,
            "60-100": elapsed_60_100,
            "100-130": elapsed_100_130,
            "vmax_mph": self.vmax,
            "sample_rate_hz": rate,
        }
        result["file"] = self._write_csv(result)
        self._append_summary(result)

        self.state = COOLDOWN
        self.samples = []
        self.runs_completed += 1
        return result

    # ------------------------------------------------------------------

    def _write_csv(self, result):
        os.makedirs(self.log_dir, exist_ok=True)
        stamp = result["when"].strftime("%Y%m%d_%H%M%S")
        tag = "" if result["complete"] else "_partial"
        path = os.path.join(self.log_dir, f"run_{stamp}{tag}.csv")
        with open(path, "w", newline="") as f:
            f.write(f"# 60-130 run, {result['when'].isoformat(timespec='seconds')}\n")
            for key in ("60-130", "60-100", "100-130"):
                if result[key] is not None:
                    f.write(f"# {key}: {result[key]:.2f} s\n")
            f.write(f"# vmax: {result['vmax_mph']:.1f} mph\n")
            w = csv.writer(f)
            w.writerow(["t_s", "mph", "kmh"])
            for t, mph in self.samples:
                w.writerow([f"{t - self.t60:.3f}", f"{mph:.1f}", f"{mph * KMH_PER_MPH:.1f}"])
        return path

    def _append_summary(self, result):
        os.makedirs(self.log_dir, exist_ok=True)
        path = os.path.join(self.log_dir, "runs.csv")
        new = not os.path.exists(path)
        with open(path, "a", newline="") as f:
            w = csv.writer(f)
            if new:
                w.writerow(["timestamp", "complete", "60-130_s", "60-100_s",
                            "100-130_s", "vmax_mph", "sample_rate_hz", "log_file"])
            w.writerow([
                result["when"].isoformat(timespec="seconds"),
                "yes" if result["complete"] else "no",
                f"{result['60-130']:.2f}" if result["60-130"] else "",
                f"{result['60-100']:.2f}" if result["60-100"] else "",
                f"{result['100-130']:.2f}" if result["100-130"] else "",
                f"{result['vmax_mph']:.1f}",
                f"{result['sample_rate_hz']:.1f}",
                os.path.basename(result["file"]),
            ])
