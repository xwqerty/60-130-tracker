"""Run detection, timing, and CSV logging (60-130 by default, any range).

State machine fed with (timestamp, mph) samples:

  ARMED      speed below the start threshold. Keeps a short pre-roll buffer
             so the log shows the launch, not just the moment of crossing.
  RECORDING  entered the instant a sample crosses the start speed. The exact
             crossing time is linearly interpolated between the sample below
             and above the threshold, so timing accuracy is much finer than
             the polling interval. Same at the split and end speeds.
  COOLDOWN   after a finished/aborted run; re-arms once speed drops back
             below the start threshold (minus a margin).

A start threshold of 0 mph is special: the clock starts at the first sample
showing movement, timed from the last stationary sample.

A run completes at the end speed, or is saved as partial if you lift early
(speed falling well below the peak before reaching it).
"""

import collections
import csv
import os
from datetime import datetime

KMH_PER_MPH = 1.609344

REARM_MARGIN_MPH = 5.0
ABORT_DROP_MPH = 4.0    # lift detection: this far below peak = run over
PREROLL_S = 3.0

ARMED, RECORDING, COOLDOWN = "ARMED", "RECORDING", "COOLDOWN"


def _interp_time(t0, v0, t1, v1, threshold):
    """Time at which speed crossed `threshold` between two samples."""
    if v1 == v0:
        return t1
    return t0 + (threshold - v0) / (v1 - v0) * (t1 - t0)


class RunTracker:
    def __init__(self, log_dir="logs", start_mph=60.0, end_mph=130.0, split_mph=None):
        if split_mph is None:
            # 60-130 keeps the traditional 100 mph split; other ranges use the midpoint
            split_mph = 100.0 if (start_mph, end_mph) == (60.0, 130.0) else (start_mph + end_mph) / 2
        self.start_mph = start_mph
        self.end_mph = end_mph
        self.split_mph = split_mph
        self.rearm_mph = max(start_mph - REARM_MARGIN_MPH, 0.0)
        self.label = f"{start_mph:g}-{end_mph:g}"
        self.split_labels = (f"{start_mph:g}-{split_mph:g}", f"{split_mph:g}-{end_mph:g}")

        self.log_dir = log_dir
        self.state = ARMED
        self.prev = None                    # (t, mph)
        self.preroll = collections.deque()  # samples before the start crossing
        self.samples = []                   # samples during the run
        self.t_start = self.t_split = self.t_end = None
        self.vmax = 0.0
        self.runs_completed = 0

    # ------------------------------------------------------------------

    def _crossed_start(self, prev_mph, mph):
        if self.start_mph == 0.0:
            return prev_mph <= 0.0 < mph    # first movement from standstill
        return prev_mph < self.start_mph <= mph

    def add_sample(self, t, mph):
        """Feed one sample. Returns a result dict when a run just ended."""
        result = None
        prev = self.prev
        self.prev = (t, mph)

        if self.state == ARMED:
            self.preroll.append((t, mph))
            while self.preroll and t - self.preroll[0][0] > PREROLL_S:
                self.preroll.popleft()
            if prev and self._crossed_start(prev[1], mph):
                self._start_run(prev, (t, mph))

        elif self.state == RECORDING:
            self.samples.append((t, mph))
            self.vmax = max(self.vmax, mph)
            if prev and prev[1] < self.split_mph <= mph:
                self.t_split = _interp_time(*prev, t, mph, self.split_mph)
            if prev and prev[1] < self.end_mph <= mph:
                self.t_end = _interp_time(*prev, t, mph, self.end_mph)
                result = self._finish(complete=True)
            elif mph < self.vmax - ABORT_DROP_MPH:
                result = self._finish(complete=False)

        elif self.state == COOLDOWN:
            if mph <= self.rearm_mph:
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
        self.t_start = _interp_time(*below, *above, self.start_mph)
        self.t_split = self.t_end = None
        self.vmax = above[1]
        self.samples = list(self.preroll) + [above]

    def _finish(self, complete):
        total = self.t_end - self.t_start if complete else None
        split1 = self.t_split - self.t_start if self.t_split else None
        split2 = self.t_end - self.t_split if (complete and self.t_split) else None

        # effective sample rate during the run proper
        run = [s for s in self.samples if s[0] >= self.t_start]
        rate = (len(run) - 1) / (run[-1][0] - run[0][0]) if len(run) > 1 else 0.0

        result = {
            "when": datetime.now(),
            "range": self.label,
            "split_labels": self.split_labels,
            "complete": complete,
            "total": total,
            "split1": split1,
            "split2": split2,
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
        path = os.path.join(self.log_dir, f"run_{self.label}_{stamp}{tag}.csv")
        with open(path, "w", newline="") as f:
            f.write(f"# {self.label} run, {result['when'].isoformat(timespec='seconds')}\n")
            for label, key in ((self.label, "total"),
                               (self.split_labels[0], "split1"),
                               (self.split_labels[1], "split2")):
                if result[key] is not None:
                    f.write(f"# {label}: {result[key]:.2f} s\n")
            f.write(f"# vmax: {result['vmax_mph']:.1f} mph\n")
            w = csv.writer(f)
            w.writerow(["t_s", "mph", "kmh"])
            for t, mph in self.samples:
                w.writerow([f"{t - self.t_start:.3f}", f"{mph:.1f}", f"{mph * KMH_PER_MPH:.1f}"])
        return path

    def _append_summary(self, result):
        os.makedirs(self.log_dir, exist_ok=True)
        path = os.path.join(self.log_dir, "runs.csv")
        new = not os.path.exists(path)
        with open(path, "a", newline="") as f:
            w = csv.writer(f)
            if new:
                w.writerow(["timestamp", "range", "complete", "total_s", "split1_s",
                            "split2_s", "vmax_mph", "sample_rate_hz", "log_file"])
            w.writerow([
                result["when"].isoformat(timespec="seconds"),
                self.label,
                "yes" if result["complete"] else "no",
                f"{result['total']:.2f}" if result["total"] else "",
                f"{result['split1']:.2f}" if result["split1"] else "",
                f"{result['split2']:.2f}" if result["split2"] else "",
                f"{result['vmax_mph']:.1f}",
                f"{result['sample_rate_hz']:.1f}",
                os.path.basename(result["file"]),
            ])
