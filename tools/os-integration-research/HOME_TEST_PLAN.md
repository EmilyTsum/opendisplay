# Sidecar native 120 Hz / HEVC home test plan

# B. Native Sidecar 120 Hz / HEVC investigation

Repository: `EmilyTsum/opendisplay`
Branch: `research/os-integration-private-api`

Confirmed before real-device testing on macOS 26:

- `SidecarDisplayManager` discovery/config/connect/disconnect client APIs are callable from an otherwise unentitled process in CI probes.
- `SidecarDisplayConfig` exposes `framerate`, `codec`, `txMaxBitrate`, `txMinBitrate`, `lowLatency`, `transport`, `keyFrameInterval`, `tilesPerFrame`, `hdr`, etc.
- Sidecar display codec enum mapping from current SidecarDisplayAgent disassembly:
  - `0` = H.264
  - `1` = HEVC
- `framerate=@120` and other numeric settings are accepted by the config object and reach the connect call path in fake-device probes.
- None of that yet proves a real iPad honors 120 Hz. Real-device measurement is required.

## B1. Build research tools

```sh
gh repo clone EmilyTsum/opendisplay
cd opendisplay
git fetch origin
git switch research/os-integration-private-api
cd tools/os-integration-research
./build-tools.sh
```

Produced tools:

- `build/sidecar-intent-probe`
- `build/sidecar-config-dump`
- `build/sidecar-native-tune`
- `build/display-refresh-probe`
- `build/sidecar-log-monitor`

## B2. Capture the untouched stock Sidecar config

Do this before changing anything:

```sh
./build/sidecar-native-tune list | tee ~/Desktop/sidecar-devices.txt
./build/sidecar-config-dump | tee ~/Desktop/sidecar-stock-config.txt
```

Important fields to retain:

- `framerate`
- `codec` and its name
- `txMaxBitrate` / `txMinBitrate`
- `lowLatency`
- `transport`
- `keyFrameInterval`
- `tilesPerFrame`
- `size` / `scale`

If multiple devices appear, use the listed index in later commands.

## B3. Measure stock Sidecar runtime

Start logging before connecting:

```sh
./build/sidecar-log-monitor | tee ~/Desktop/sidecar-stock-live.log
```

Connect the iPad normally from Control Center > Screen Mirroring / Sidecar.

In another terminal:

```sh
./build/display-refresh-probe list | tee ~/Desktop/sidecar-stock-displays.txt
```

Identify the Sidecar display ID (normally the newly appearing non-built-in display), then:

```sh
./build/display-refresh-probe measure DISPLAY_ID 5 \
  | tee ~/Desktop/sidecar-stock-refresh.txt
```

This gives both the Quartz-reported mode refresh and measured CVDisplayLink callback cadence.

## B4. Capture Sidecar click/connection status transitions

Disconnect Sidecar first. Then:

```sh
./build/sidecar-intent-probe 60 | tee ~/Desktop/sidecar-intent.txt
```

During the 60 seconds:

1. Open Control Center > Screen Mirroring.
2. Select the iPad once.
3. Wait until connected.
4. Disconnect it once.

This trace is needed to identify the exact `SidecarDevice.status` transition for a future OpenDisplay intent bridge.

## B5. 120 Hz only — first native tuning test

First dry-run:

```sh
./build/sidecar-native-tune connect --device 0 --fps 120 \
  | tee ~/Desktop/sidecar-120-dryrun.txt
```

Check the printed `stock config` versus `requested config`. Only `framerate` should differ.

Then apply:

```sh
./build/sidecar-native-tune connect --device 0 --fps 120 --apply \
  | tee ~/Desktop/sidecar-120-connect.txt
```

Immediately measure:

```sh
./build/display-refresh-probe list
./build/display-refresh-probe measure DISPLAY_ID 5 \
  | tee ~/Desktop/sidecar-120-refresh.txt
```

Do not call this successful unless measured cadence moves from ~60 to ~120 Hz (or otherwise clearly reflects the new mode).

To return to a stock copied config through the same API:

```sh
./build/sidecar-native-tune disconnect --device 0 --apply
./build/sidecar-native-tune connect --device 0 --apply
```

Normal Control Center Sidecar also remains the fallback.

## B6. Codec experiment

Read `sidecar-stock-config.txt` first.

If stock codec is already `1 (HEVC)`, do not waste a test forcing HEVC; keep stock codec and focus on 120 Hz/bitrate.

If stock is H.264, test codec alone first:

```sh
./build/sidecar-native-tune connect --device 0 --codec hevc
# inspect dry-run, then:
./build/sidecar-native-tune connect --device 0 --codec hevc --apply
```

Capture Sidecar logs and refresh again. The current enum is:

- `h264` -> `codec=@0`
- `hevc` -> `codec=@1`

Then, only after both single-variable tests are understood, combine:

```sh
./build/sidecar-native-tune connect --device 0 --fps 120 --codec hevc --apply
```

## B7. Bitrate and latency tuning

Only after native 120 Hz works or definitively fails.

Start with a single max-bitrate change:

```sh
./build/sidecar-native-tune connect --device 0 --max-mbps 100
```

Inspect dry-run, then apply if sensible. Increase in conservative steps rather than jumping immediately to an extreme value.

Test `--low-latency 1` separately before combining it with bitrate/120 Hz.

Suggested progression:

1. stock
2. 120 Hz only
3. HEVC only, if stock was H.264
4. 120 Hz + HEVC
5. max bitrate only
6. low latency only
7. finally combine the proven settings

## B8. What to save/upload after the Sidecar tests

Minimum useful set:

- `sidecar-stock-config.txt`
- `sidecar-intent.txt`
- `sidecar-stock-refresh.txt`
- `sidecar-120-refresh.txt`
- `sidecar-stock-live.log`
- 120 Hz/HEVC experiment Sidecar log
- exact command used for each successful/failed connection

---
