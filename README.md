# 60-130 Tracker

Laptop-based 60–130 mph timer for a BMW M240i, using the **MHD WiFi adapter**
(ENET mode) you already tune with. No installs — plain Python 3, standard
library only.

The moment the car crosses **60 mph** it starts logging; crossing **130 mph**
stops the clock. Every run is saved as a CSV trace plus a one-line summary,
including 60–100 and 100–130 splits. Lifting early saves a partial run.

## Usage

1. Plug the MHD adapter into the OBD port, ignition on (engine running).
2. On the laptop, join the adapter's WiFi network (**"MHD ENET xxxx"**).
3. Make sure the MHD phone app is **disconnected** — only one tool can talk
   to the car at a time.
4. Run:

   ```
   python3 tracker.py
   ```

It broadcasts for the car's gateway automatically. You'll see a live speed
readout; do your pull, results print immediately:

```
==============================================
  60-130:    13.07 s
  60-100:     6.41 s
  100-130:    6.65 s
  vmax:      130.5 mph
  samples:  25 Hz
  saved:    logs/run_20260708_122157.csv
==============================================
```

After a run, slow below 55 mph and it re-arms for the next pull. `Ctrl+C`
quits (and saves an in-progress run as partial).

### Options

| Flag | Meaning |
| --- | --- |
| `--host IP` | Skip auto-discovery, connect to this gateway IP |
| `--ecu 0x12` | ECU to poll (default `0x12`, the DME) |
| `--log-dir DIR` | Where run CSVs go (default `logs/`) |
| `--runs N` | Exit after N runs (default: run until Ctrl+C) |
| `--sim` | Simulated pull — test everything without the car |
| `--sim-speedup N` | Run the simulator N× faster than real time |

Dry-run on the couch: `python3 tracker.py --sim`

## Output

- `logs/run_<timestamp>.csv` — full speed trace per run. `t_s` is zeroed at
  the 60 mph crossing; a few seconds of pre-roll (negative `t_s`) show the
  launch. Partial runs are tagged `_partial`.
- `logs/runs.csv` — one summary row per run, accumulates across sessions.

## How it works

- The MHD adapter bridges WiFi onto the car's diagnostic Ethernet (ENET).
  The tool speaks BMW's **HSFZ** protocol — UDP `6811` to discover the
  gateway, TCP `6801` for diagnostics — same as ISTA/E-SYS.
- Speed comes from the DME via UDS `ReadDataByIdentifier 0xF40D` (vehicle
  speed), falling back to classic OBD `01 0D` if needed.
- The PID reports whole km/h, but the exact 60/100/130 crossing times are
  **linearly interpolated** between samples, so timing resolution is much
  finer than the polling rate.

Files: `tracker.py` (CLI) · `hsfz.py` (ENET/HSFZ transport) ·
`speed.py` (speed sources + simulator) · `runlog.py` (run state machine + CSV).

## Notes

- Timing is from the DME's reported wheel speed — same signal a phone GPS
  box won't beat for consistency, but absolute accuracy depends on tire
  size (speedo correction) like every OBD-based timer.
- Obvious but: run it with a passenger holding the laptop, on a closed
  course / somewhere legal.
