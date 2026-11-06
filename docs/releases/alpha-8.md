# Mesh Utility Alpha 8

Alpha 8 is now available.

This release focuses on faster startup after reopening the app, better control over how much cloud history is downloaded, more accurate zone scoring, and smarter scan transitions while moving between covered and uncovered areas.

---

## Live App

Use the web app:
[https://mesh-utility.org/](https://mesh-utility.org)

---

## What's Improved

### Startup / Cached History

* Synced scan history is now cached locally instead of only keeping the unsynced upload queue
* Reopening the app after time away should show your last synced scan set much faster
* Offline reopen behavior is more reliable because recent synced history is available on-device

---

### Sync / Download Scope

* Added a Sync Download Scope setting so cloud history can be loaded globally or within a chosen radius
* Worker history and coverage requests now support radius-based filtering
* Sync status text now better distinguishes cached local scans from scans fetched from the network

---

### Coverage Accuracy

* Zone RSSI and SNR values now use real averages instead of sticking to the strongest reading
* Coverage summaries now reflect repeated scans of the same area more honestly
* Matching worker-side aggregation keeps map zones and synced coverage data consistent

---

### Smart Scan Behavior

* Smart scan now re-evaluates immediately when you move into a new hex instead of waiting on the old throttle window
* Leaving a recently covered zone now triggers discover mode more promptly
* This reduces cases where the app briefly says scan skipped after you have already entered a new zone

---

## Why This Matters

Alpha 8 is about making long-term scanning sessions feel faster and more trustworthy:

* You see useful history sooner when reopening the app
* You can limit cloud downloads to the area that matters to you
* Zone quality values better match the scans actually collected
* Smart scan responds faster when you drive into new territory

---

## Links

* Web App: [https://mesh-utility.org/](https://mesh-utility.org)
* Source: [https://github.com/mesh-utility/mesh-utility](https://github.com/mesh-utility/mesh-utility)
* Bugs: [https://discord.gg/3QPUbT36v2](https://discord.gg/3QPUbT36v2)
* Features: [https://discord.gg/j6m4csmTra](https://discord.gg/j6m4csmTra)

## Thank You

Thank you to everyone testing real-world map coverage, sharing screenshots, and calling out edge cases in startup, averaging, and smart-scan behavior. Those reports directly shaped Alpha 8.
