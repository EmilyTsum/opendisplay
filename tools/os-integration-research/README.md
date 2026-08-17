# Sidecar intent probe (research only)

Passive diagnostic only. It dynamically loads SidecarCore, reads SidecarDisplayManager device state,
and observes the Sidecar display-agent Darwin notification. It does not connect, disconnect, inject,
or modify system services.

Build on macOS:

```sh
clang -fobjc-arc -framework Foundation -framework CoreFoundation \
  sidecar-intent-probe.m -o sidecar-intent-probe
./sidecar-intent-probe 60
```

During the 60-second window, open Control Center > Screen Mirroring and select/deselect the iPad.
The log is used to identify the Sidecar status transition that corresponds to user connection intent.

## Stock Sidecar configuration dump

`sidecar-config-dump.m` is read-only. It dumps the stock `SidecarDisplayConfig` for every currently
visible Sidecar device, including the numeric codec/transport values that cannot be safely guessed
from the private API surface.

```sh
clang -fobjc-arc -framework Foundation sidecar-config-dump.m -o sidecar-config-dump
./sidecar-config-dump
```

Run this before any custom-config connection experiment. Preserve the output as the baseline.

## Sidecar display codec enum (macOS 26.5.2 / SidecarDisplayAgent)

Reverse-engineering of the current SidecarDisplayAgent diagnostic mapping confirms:

- `0` = H.264
- `1` = HEVC
- other values fall through to the unknown/empty diagnostic path

This is not guessed from the property name: the executable contains the literal labels `H.264` and `HEVC`, and its codec-to-label branch compares the codec value directly against `0` and `1`.

For real-device native Sidecar tuning, preserve the stock config and change one field at a time. The first codec experiment should therefore use `codec = @1` only after logging the stock value.


## Native Sidecar tuner (opt-in)

`sidecar-native-tune.m` copies the real stock `SidecarDisplayConfig` for a visible device and changes only fields explicitly requested on the command line. It is dry-run by default. `--apply` is required before it calls `connectToDevice:withConfig:completion:` or `disconnectFromDevice:completion:`.

Examples:

```sh
clang -fobjc-arc -framework Foundation sidecar-native-tune.m -o sidecar-native-tune
./sidecar-native-tune list
./sidecar-native-tune dump --device 0
./sidecar-native-tune connect --device 0 --fps 120
./sidecar-native-tune connect --device 0 --fps 120 --apply
./sidecar-native-tune connect --device 0 --fps 120 --codec hevc --max-mbps 100 --low-latency 1
```

Do the experiments one variable at a time. A successful completion only means Sidecar accepted the request; it does not prove the receiver actually ran at 120 Hz or used the requested codec.

Build all three research tools at once:

```sh
./build-tools.sh
```

The binaries are placed under `build/` by default.
