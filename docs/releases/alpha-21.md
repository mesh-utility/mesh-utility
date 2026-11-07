# Mesh Utility Alpha-21

## Map history
- All days (all-time history) no longer freezes the app. Saved history and each cloud day load in the background, and the status line shows progress ("Loading saved history (n)" and "Loading history n/total days").
- If an all-days load is interrupted before it finishes, the next startup uses the last 7 days for Cloud History and Deadzone Retrieval so Settings stays reachable. Turn All days back on in Settings when you want the full history again.

## Coverage map
- Zoomed-out coverage is drawn as larger hex groups instead of every individual cell. Zoom in to see the exact cells.
- Map tips no longer scroll while the map sits idle. That scrolling kept redrawing the map and used CPU and battery. Each tip now stays still and changes to the next one every 10 seconds.

## Updating
- Alpha-19 and later can update from inside the app (Settings > App updates).
- Alpha-17 and Alpha-18 can't update themselves: install this APK once by hand, or use Obtainium.

[Add to Obtainium](https://apps.obtainium.imranr.dev/redirect?r=obtainium://add/https://github.com/mesh-utility/mesh-utility)
