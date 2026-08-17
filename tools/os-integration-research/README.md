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
