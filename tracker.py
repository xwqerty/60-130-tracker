#!/usr/bin/env python3
"""60-130 mph timer for BMW, over the MHD WiFi (ENET) adapter.

Usage:
  1. Plug in the MHD adapter, ignition on.
  2. Join the "MHD ENET xxxx" WiFi network on this laptop.
  3. python3 tracker.py

The tool finds the car's gateway automatically, polls vehicle speed as fast
as the DME answers, and the moment you cross 60 mph it starts logging.
Crossing 130 mph stops the clock; every run is saved to logs/ as CSV and
summarized in logs/runs.csv. Lifting early saves a partial run.

Test without the car:   python3 tracker.py --sim
"""

import argparse
import sys
import time

import hsfz
import runlog
import speed

KMH_PER_MPH = speed.KMH_PER_MPH

# If UDP discovery fails, try these directly (adapter/gateway defaults).
FALLBACK_HOSTS = ["192.168.16.254", "169.254.128.7"]


def parse_args():
    p = argparse.ArgumentParser(description="BMW 60-130 timer via MHD ENET adapter")
    p.add_argument("--host", help="gateway IP (skip UDP auto-discovery)")
    p.add_argument("--ecu", type=lambda s: int(s, 0), default=hsfz.DME_ADDR,
                   help="ECU address to poll (default 0x12 = DME)")
    p.add_argument("--log-dir", default="logs", help="where to save run CSVs")
    p.add_argument("--runs", type=int, default=0,
                   help="exit after this many runs (0 = run until Ctrl+C)")
    p.add_argument("--sim", action="store_true", help="simulated pull, no car needed")
    p.add_argument("--sim-speedup", type=float, default=1.0,
                   help="run the simulator N x faster than real time")
    return p.parse_args()


def connect(args):
    if args.sim:
        return speed.SimSpeedSource(speedup=args.sim_speedup), None

    hosts = [args.host] if args.host else []
    if not args.host:
        print("Searching for the car (UDP broadcast)...")
        found = hsfz.discover()
        if found:
            ip, ident = found
            print(f"Gateway found at {ip} ({ident[6:].decode('latin1').strip()!r})")
            hosts = [ip]
        else:
            print("No answer to discovery; trying known adapter IPs...")
            hosts = FALLBACK_HOSTS

    last_err = None
    for host in hosts:
        client = hsfz.HsfzClient(host)
        try:
            client.connect()
            src = speed.EnetSpeedSource(client, ecu=args.ecu)
            mode = src.start()
            print(f"Connected to {host}, reading speed via {mode}")
            return src, client
        except Exception as e:
            last_err = e
            client.close()
            print(f"  {host}: {e}")

    print(f"\nCould not connect to the car: {last_err}", file=sys.stderr)
    print("Checks: adapter LED on? Laptop joined the 'MHD ENET' WiFi? "
          "Ignition on? MHD phone app disconnected (only one tool can "
          "talk to the car at a time)?", file=sys.stderr)
    sys.exit(1)


def print_result(r):
    print("\r" + " " * 78)
    print("=" * 46)
    if r["complete"]:
        print(f"  60-130:   {r['60-130']:6.2f} s")
    else:
        print("  RUN ABORTED (lifted before 130)")
    if r["60-100"] is not None:
        print(f"  60-100:   {r['60-100']:6.2f} s")
    if r["100-130"] is not None:
        print(f"  100-130:  {r['100-130']:6.2f} s")
    print(f"  vmax:     {r['vmax_mph']:6.1f} mph")
    print(f"  samples:  {r['sample_rate_hz']:.0f} Hz")
    print(f"  saved:    {r['file']}")
    print("=" * 46)


def main():
    args = parse_args()
    source, client = connect(args)
    tracker = runlog.RunTracker(log_dir=args.log_dir)

    print("Armed. Cross 60 mph under power to start the clock. Ctrl+C to quit.\n")
    live = sys.stdout.isatty()  # the \r-updating speed line only makes sense on a terminal
    last_draw = 0.0
    try:
        while True:
            try:
                t, kmh = source.read()
            except Exception as e:
                print(f"\nread error: {e} -- retrying", file=sys.stderr)
                time.sleep(0.5)
                continue

            mph = kmh / KMH_PER_MPH
            result = tracker.add_sample(t, mph)
            if result:
                print_result(result)
                if args.runs and tracker.runs_completed >= args.runs:
                    print(f"\n{tracker.runs_completed} run(s) logged in {args.log_dir}/")
                    break

            now = time.monotonic()
            if live and now - last_draw > 0.1:  # don't spam the terminal
                last_draw = now
                if tracker.state == runlog.RECORDING:
                    status = f"RECORDING  +{t - tracker.t60:5.2f} s"
                elif tracker.state == runlog.COOLDOWN:
                    status = "cooldown (slow below 55 to re-arm)"
                else:
                    status = "armed"
                sys.stdout.write(f"\r  {mph:6.1f} mph   [{status}]" + " " * 12)
                sys.stdout.flush()
    except KeyboardInterrupt:
        result = tracker.flush()
        if result:
            print_result(result)
        print(f"\nDone. {tracker.runs_completed} run(s) logged in {args.log_dir}/")
    finally:
        source.stop()
        if client:
            client.close()


if __name__ == "__main__":
    main()
