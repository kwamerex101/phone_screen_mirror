# Changelog

## 0.9.0 - 2026-11-08

- Redesign the Settings popover with glass styling and two control mode cards.
- Default to Direct USB for live video. Set up Wired Control to tap, swipe, type,
  and go Home without WebDriverAgent on supported Apple silicon Macs with
  macOS 27, Xcode 27, and an iPhone on iOS 27 or later.
- Keep WebDriverAgent available for XCTest control and accessibility tools.
- Route wired touches to the active screen on devices with multiple displays.
- Omit the experimental Bluetooth control option after pairing tests on the Duo.
- Correct the runner build target for Xcode SDKs with a minimum of iOS 15.

## 0.8.0 - 2026-11-06

- Add native USB video capture with direct AVFoundation preview. One tested
  phone averaged about 55 FPS; an isolated capture probe reached 59.4 FPS.
  Frame rates vary with device and workload.
- Adapt the preview to the phone's current screen size and orientation, with
  refreshed touch geometry after display changes.
- Keep WDA MJPEG video as a fallback and correct its stream orientation.
- Retain only the newest pending video update while the UI is busy. Order USB
  availability and frame updates together, and reject ambiguous multi-phone
  USB capture so video and control do not select different phones.
- Fix a window-close crash caused by a deferred callback accessing a released
  window, and cancel callbacks during shutdown.
- Recover MJPEG connections when their forwarded port becomes available later.
- Preserve actionable runner-install errors and classify the complete installer
  output before shortening it for display.
- Preserve video while WDA control reconnects. Avoid redundant XML snapshots
  after a classified WDA source transport failure.
- Improve runner builds for current Xcode SDKs and retain the correct signing
  identity when branding a runner built for another team.
- Update the bundled MCP server to 1.3.1.

Fast USB capture may route iPhone audio to the Mac. iMirror does not add audio
playback. WDA control still requires a runner signed for the connected device.
