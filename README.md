# Recovery Lab for iPhone

A small recorder app. It keeps a heart-rate band connected over Bluetooth in the background,
saves heart rate and beat-to-beat intervals minute by minute, and uploads each day's file to a
private GitHub repository. Scoring and the dashboard run elsewhere (the Recovery Lab page in Claude).

- Works with any band that offers the standard Bluetooth Heart Rate service (for a WHOOP band,
  HR Broadcast must be on).
- No account, no analytics. The only network calls are uploads to the repository you name.
- Not affiliated with WHOOP. Not a medical device.

## How it works

| Part | What it does |
| --- | --- |
| `Core/` | Parses heart-rate packets and builds per-minute rows. Plain Swift with unit tests. |
| `App/BandManager.swift` | Bluetooth connection, background mode, automatic reconnect. |
| `App/MinuteStore.swift` | Saves minutes on the phone and tracks what still needs uploading. |
| `App/Uploader.swift` | Puts `minutes/YYYY-MM-DD.json` into the data repository every 10 minutes. |

Each row is `[minuteOfDay, averageHeartRate, rrCount, sumOfSquaredRRDifferences, differenceCount]`.

## Build

Every push to `main` runs the tests, builds an unsigned `.ipa` on a GitHub macOS runner, and
publishes it as the `latest` release. No Mac is needed.

## Install on your own iPhone (from Windows)

1. Download `RecoveryLab.ipa` from the latest release.
2. Install Sideloadly (or AltStore), plug in the iPhone, and install the `.ipa` with your Apple ID.
3. On the iPhone: Settings → General → VPN & Device Management → trust your Apple ID, and turn on
   Developer Mode under Privacy & Security.
4. Open the app, allow Bluetooth, pick your band, then paste a GitHub token under Settings.

With a free Apple ID the app has to be re-signed every 7 days.

## Token

Create a fine-grained personal access token that can reach only the data repository, with
**Contents: Read and write**. The app keeps it in the iOS Keychain.
