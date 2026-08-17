# macOS Bluetooth AAC bitrate research

Read-only research for the AAC bitrate/link-adaptation issue. This is deliberately isolated from OpenDisplay shipping code.

`bt-aac-link-monitor.m` dynamically loads Apple's private BluetoothAudio framework and reads `CBController.controllerInfoAndReturnError:` -> `CBControllerInfo.audioLinkQualityArray`.

Each active `CBAudioLinkQualityInfo` exposes the metrics needed to diagnose AAC bitrate adaptation: `bitRate`, `codecType`, RSSI, SNR, noise floor, retransmit rate, jitter-buffer duration, Bluetooth band, and AOS state.

The monitor does not change preferences, restart bluetoothd, disconnect devices, or alter the negotiated codec.

## Preferred real-device diagnostic: unified-log monitor

`bt-aac-log-monitor.sh` is the practical read-only diagnostic on a normal Mac. The more direct private `CBControllerInfo.audioLinkQualityArray` path exists, but current macOS rejects it without `com.apple.bluetooth.system`.

The HAL itself emits the useful adaptation event:

`SetLinkAdaptiveEncoderRateFromBT Updating AAC Encoder to <N> kbps ...`

Run the monitor while playing audio and reproduce the 128 kbps state. It also captures AAC encoder creation, target/actual bitrate, and A2DP messages. No Bluetooth settings are changed.

The current macOS 26 HAL disassembly shows that the bitrate supplied by the Bluetooth stack is used directly for AAC link adaptation. The HAL does not contain a simple fixed `128 kbps` choice at this point. It also changes the AAC bandwidth limit by bitrate tier: below 129 kbps, 129–160 kbps, and 161 kbps or above.
