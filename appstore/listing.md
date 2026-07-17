# App Store listing — copy & paste

Character limits are enforced by App Store Connect; each field below is within them.

## App name  (max 30)
```
60-130: Acceleration Timer
```
(26 chars. The on-device name stays "60-130". If that name is taken in App
Store Connect, fall back to: `60-130 Acceleration Timer` or `Launch: 0-60 & 60-130`.)

## Subtitle  (max 30)
```
0-60, 60-130 & custom, GPS/OBD
```
(29 chars.)

## Promotional text  (max 170 — editable any time, no review needed)
```
Time 0-60, 60-130, or any range you set — GPS-accurate, straight from your phone. Add an OBD adapter for higher precision. Every run logged with splits and top speed.
```

## Keywords  (max 100, comma-separated, no spaces)
```
acceleration,0-60,60-130,timer,speed,gps,obd,elm327,launch,track,dyno,performance,bmw,mph,logger
```
(99 chars. Don't repeat words from the app name; Apple already indexes those.)

## Description  (max 4000)
```
60-130 is a dead-simple, honest acceleration timer for your car. Pick a speed
range — 0-60, 60-130, 30-100, or any custom range up to 160 mph — and the clock
starts the instant you cross the start speed and stops the instant you hit the
end. No fiddling mid-run.

WORKS WITH JUST YOUR PHONE
Start timing with nothing but your iPhone's GPS. No adapter, no account, no
setup. Want sharper, higher-rate numbers? Connect an OBD adapter and the app
reads speed straight from the car.

ACCURATE — AND IT SHOWS YOU
Your phone's GPS gives an absolutely-referenced ground speed. The app
continuously cross-checks it against the car's reported speed and corrects for
tire size and setup, so your times stay tied to real-world truth instead of a
factory estimate. It's the same GPS-referenced principle dedicated performance
meters are built on — and you can inspect every run yourself.

FEATURES
• Time 0-60, 60-130, 30-100, or any custom range (0-160 mph)
• Auto start/stop at your chosen thresholds — nothing to tap mid-run
• Live speed, elapsed timer, and a progress bar while you record
• Splits and top speed for every run
• Personal-best highlighting across your runs
• Every run saved as a CSV you can open in Files or a spreadsheet
• Continuous GPS calibration for true-ground-speed accuracy
• No accounts, no ads, no tracking — your data stays on your device

CONNECTION OPTIONS
• Phone GPS only — works on any car, or none
• Wi-Fi OBD (generic ELM327 adapter) — works on most 1996+ vehicles
• BMW ENET / MHD Wi-Fi adapter — high-rate speed on F/G-series BMWs

FOR TRACK & CLOSED-COURSE USE
60-130 is built for the track, a closed course, or private property. Never use
it on public roads, and never operate it while driving — a passenger runs the
app. Timing results are estimates provided for entertainment.

No sign-up. No subscription. Just launch and time.
```

## Support URL  (required)
```
https://xwqerty.github.io/60-130-tracker/
```
(The privacy page doubles as a landing/contact page — it has your email. If you
want a dedicated support page later, add one; for launch this is fine.)

## Marketing URL  (optional)
```
https://github.com/xwqerty/60-130-tracker
```

## Privacy Policy URL  (required)
```
https://xwqerty.github.io/60-130-tracker/
```

## Category
- Primary: **Sports**
- Secondary: **Utilities**

## Age rating
Answer every content question "None" → results in **4+**.

## App Privacy (data collection questionnaire)
Answer **"Data Not Collected."** Location is used only on-device to time and
calibrate runs and never leaves the phone, so under Apple's definition it is not
"collected." (If the questionnaire nudges you to list Location: mark it used for
"App Functionality," "Not linked to identity," and "Not used for tracking.")

## Export compliance
Already handled in the app (Info.plist `ITSAppUsesNonExemptEncryption = false`),
so App Store Connect won't ask on each upload. If prompted anyway: the app uses
no non-exempt encryption → **exempt**.
