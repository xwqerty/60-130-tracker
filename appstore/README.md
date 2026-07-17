# App Store assets

## Screenshots (`screenshots/`)

Three staged screenshots at **1320×2868** (6.9" iPhone — iPhone 16 Pro Max),
the size App Store Connect requires. Apple auto-scales these down for smaller
iPhones, so this one set is enough for an iPhone-only app.

| File | Caption | Shows |
| --- | --- | --- |
| `1_hero.png` | "Time 0-60, 60-130, or any range you set" | Main screen: live speed, range slider, presets, START LOG, logged results with BEST badge |
| `2_recording.png` | "The clock starts the instant you cross" | Live recording: elapsed timer, progress bar, big speed readout |
| `3_intro.png` | (built-in onboarding copy) | First-launch intro — brand, tagline, GPS-calibration note |

Captured in demo mode on a clean 9:41 status bar; the "SIMULATOR" label was
temporarily hidden for the shots only (the shipped app still shows it in demo
mode).

## Upload

In App Store Connect → your app → the version → **App Previews and
Screenshots** → 6.9" Display → drag these three in, in order.

## Still to do in App Store Connect
- Privacy policy URL: https://xwqerty.github.io/60-130-tracker/
- App privacy "nutrition label": declare Location (used on device, not collected)
- Age rating, category, export compliance (no non-exempt encryption → exempt)
- Recommended: a TestFlight beta round before public release
