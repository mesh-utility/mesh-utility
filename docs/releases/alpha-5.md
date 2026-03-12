# Mesh Utility Alpha 5

Alpha 5 is now available.

This release focuses on making the app feel clearer, faster to understand, and more dependable during real mapping sessions. A lot of work in this version went into scan flow, reconnect behavior, status clarity, and reducing confusion in the map UI while scans are running.

## Live App

Use the live web app here:  
[mesh-utility.org](https://mesh-utility.org)

## What Improved In Alpha 5

- **Clearer scan status and live feedback**
  - Status wording is more user-friendly during active discovery.
  - Live scan feedback is easier to follow while the app is working.
  - Discovery results are presented more clearly as they arrive.

- **Better scan controls**
  - Start/pause behavior is more consistent.
  - Force scan behavior is more predictable and aligned with scan timing.
  - Countdown behavior has been improved so timing is easier to trust.

- **Smarter scan flow**
  - Smart-scan behavior has been refined to avoid unnecessary actions.
  - Scan timing and trigger behavior are more consistent over longer runs.
  - Better handling around scan cycles and follow-up scan logic.

- **Reconnect and BLE reliability improvements**
  - Improved handling around reconnecting to known devices.
  - Better behavior when previously connected devices are involved.
  - Improved scan fallback handling for tougher BLE discovery cases.

- **Map usability improvements**
  - Better top status presentation and scrolling behavior for longer messages.
  - Improved on-map controls and tip behavior.
  - Better alignment between selected repeaters/nodes and map filtering behavior.

- **UI polish and stability fixes**
  - Multiple overflow/layout issues addressed.
  - Better handling of long labels and narrow widths.
  - Additional cleanup to reduce stale state behavior.

## Why This Matters

Alpha 5 is mainly about day-to-day usability. The app should now be easier to read, easier to control during active scanning, and more reliable when reconnecting and continuing coverage mapping sessions.

## Feedback Links

If you hit a bug, report it here:  
[Bug Reports](https://discord.gg/3QPUbT36v2)

If you want to request features or improvements, post here:  
[Feature Requests](https://discord.gg/j6m4csmTra)

## Thank You

Thank you to everyone testing and sharing detailed logs, screenshots, and edge cases. Those reports directly shaped this release and helped prioritize the improvements in Alpha 5.
