# Mesh Utility Alpha 6

Alpha 6 is now available.

This release focused on Bluetooth connection reliability (especially on Linux), faster error recovery, better visual feedback, and a complete scan history redesign.

## Live App

Use the live web app here:  
[mesh-utility.org](https://mesh-utility.org)

## What's Changed In Alpha 6

| Area | Change | Why It Matters |
|------|--------|----------------|
| **Bluetooth Connection** | Rewrote Linux connection flow to match MeshCore behavior | Connects faster and recovers from dropped links more reliably |
| **Bluetooth Connection** | Radio-not-found errors detected immediately instead of ~46s wait | You'll know right away if your radio is off or out of range |
| **Bluetooth Connection** | Direct fallback connection when scan can't find the radio | Connects even when the radio doesn't show up in scan results |
| **Bluetooth Pairing** | PIN prompt appears instantly when pairing starts | No more waiting or wondering if the PIN dialog will show up |
| **Bluetooth Pairing** | Full rewrite of trust, remove, and re-pair handling | Fixes cases where pairing silently failed or got stuck |
| **Connection Feedback** | Friendly status messages replace raw errors | Clear messages like "Device not found – is your radio powered on?" |
| **Connection Feedback** | Recovery scan reduced from 8 seconds to 3 seconds | Gets you reconnected faster after a dropped connection |
| **Connection Feedback** | Green snackbar on successful connect | Clear visual confirmation that your radio is connected |
| **Connections Page** | Auto-scans when you open the page | No need to manually tap Scan every time |
| **Scan History** | New card-based layout with CSV export | Easier to read, search, and export your scan data |
| **Map Filter** | Node filter respects Stats Radius | Only shows nodes within your chosen distance |
| **Map Stats** | Stats bar cards are tappable | Tap Nodes or Scans on the map to jump directly to those pages |
| **Map Stats** | Radius filtering works correctly | Distance-based filtering actually limits to your chosen radius |
| **Dead Zones** | Fixed retrieval and display | Dead zones show up accurately on the map |
| **Navigation** | Fixed sidebar layout overflow | All menu items are always visible and scrollable |
| **Settings** | Auto-connect toggle works on Android | Toggle state stays in sync with actual behavior |
| **Help Page** | Content loads instantly | Help page opens without delay |
| **Translation Tool** | Concurrency and fallback model support | Faster translations with retry logic |
| **CI/CD** | Streamlined release artifact builds | Cleaner pipeline with manual tag-based rebuilds |
| **Worker** | Batch sync improvements | More reliable cloud sync for scan uploads |

## Why This Matters

Alpha 6 is about making the radio connection experience trustworthy. You should be able to connect your radio, see clear feedback at every step, and recover quickly if something goes wrong — especially on Linux where Bluetooth has been the most challenging.

## Links

- **Web App:** [mesh-utility.org](https://mesh-utility.org)
- **Source Code:** [github.com/mesh-utility/mesh-utility](https://github.com/mesh-utility/mesh-utility)
- **Bug Reports:** [Discord #bugs](https://discord.gg/3QPUbT36v2)
- **Feature Requests:** [Discord #feature-requests](https://discord.gg/j6m4csmTra)

## Thank You

Thank you to everyone testing with real radios and sharing feedback, screenshots, and edge cases. Those reports directly shaped the improvements in Alpha 6.
