# macOS Bluetooth AAC bitrate research

Read-only research for the AAC bitrate/link-adaptation issue. This is deliberately isolated from OpenDisplay shipping code.

`bt-aac-link-monitor.m` dynamically loads Apple's private BluetoothAudio framework and reads `CBController.controllerInfoAndReturnError:` -> `CBControllerInfo.audioLinkQualityArray`.

Each active `CBAudioLinkQualityInfo` exposes the metrics needed to diagnose AAC bitrate adaptation: `bitRate`, `codecType`, RSSI, SNR, noise floor, retransmit rate, jitter-buffer duration, Bluetooth band, and AOS state.

The monitor does not change preferences, restart bluetoothd, disconnect devices, or alter the negotiated codec.
