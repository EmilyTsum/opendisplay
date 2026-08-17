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
