# AWDL link diagnostics — macOS 26 probe

Read-only findings from macOS 26 runtime/binary probes. This is research-only and is not part of the upstream AWDL PR.

## Public transport layer

OpenDisplay selects the peer-to-peer route through Network.framework (`includePeerToPeer`, discovered `NWInterface`, `requiredInterface`). Network.framework identifies the interface but does not expose Wi-Fi RF/PHY metadata such as channel width or MCS.

## Private read-only telemetry path

`/System/Library/PrivateFrameworks/CoreWiFi.framework/CoreWiFi` contains `CWFApple80211` with:

- `-initWithInterfaceName:`
- `-channel:`
- `-txRate:` / `-rxRate:`
- `-maxLinkSpeed:`
- `-MCSIndex:`
- `-RSSI:`
- `-activePHYMode:`
- `-AWDLSyncChannelSequence:`
- `-AWDLStatistics:`
- `-AWDLSidecarDiagnostics:`
- `-AWDLMasterChannel:` / `-AWDLSecondaryMasterChannel:`

`CWFChannel` exposes:

- `channel` (number)
- `band`: 1 = 2.4 GHz, 2 = 5 GHz, 3 = 6 GHz
- `width`: actual MHz (20/40/80/160 observed in construction probe)

CoreWiFi log strings label Tx rate in Mbps. `CWFLinkQualityMetric` exposes `txRate`/`rxRate` as doubles and RSSI as dBm.

The custom OpenDisplay branch dynamically loads CoreWiFi and binds only to `awdl0`; it does not fall back to the infrastructure interface because that could mislabel the AP's channel/rate as AWDL metadata. Failure or API drift returns no metadata and never affects streaming.

## Frequency mapping

- 2.4 GHz: channel 1..13 => 2407 + 5*n MHz; channel 14 => 2484 MHz
- 5 GHz: 5000 + 5*n MHz
- 6 GHz: 5950 + 5*n MHz; channel 2 special case => 5935 MHz

## Physical validation still required

CI has no Wi-Fi hardware / `awdl0`, so a real Mac+iPad run must confirm that `CWFApple80211("awdl0")` yields live channel/rate/RSSI values during OpenDisplay traffic. The custom HUD hides absent values.
