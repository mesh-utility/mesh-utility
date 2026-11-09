# Mesh Utility Alpha-23

## Fixes

- The map no longer opens on another user's area for visitors who haven't shared their location; it shows a general view until you allow location.
- The scan countdown starts when a discovery request is sent, including a force scan while the scan loop is running. It no longer sits frozen until the radio answers.
- Periodic cloud sync reads the server clock from an HTTP Date header such as `Mon, 09 Nov 2026 05:52:01 GMT`. It no longer logs that it is waiting for an internet time anchor on every tick.
- A states or counties download on an older server is centered on your location when you are inside the selected area. Choosing Pennsylvania, New York, and Ontario while standing in central Pennsylvania no longer asks for a circle around a distant box center.
- Scan History says "1 scan" when the list has one row.
- History opened from a map cell is titled "Cell history".
- The cell history list keeps its scroll position.
- A short or shared node-id prefix no longer copies another radio's name. A radio name ending in "· synced" means that row was recorded by a different radio than the one connected now.
- Background scanning keeps running with the screen off: the scan notification stays up while the radio reconnects, and the app reconnects automatically.
- Background scanning asks once to be exempt from battery optimization, so Android doesn't cut the radio link while the screen is off.
- Map tips and map tooltips now wrap so the full text is readable.

## Enhancements

- The map shows general coverage as soon as it opens, even before your first Sync.
- Settings is grouped into Radio / Connection, Scanning, Map & Display, Data & Cache, App updates, and About.
- Data & Cache > Scan cache area limits what is downloaded and kept: a radius around your last location (10, 25, 50, 100, 250, 500, or 800 miles), states and provinces, US counties, or Global. Changing it downloads the new area or trims scans that no longer fit.
- Download where I travel is off by default. Outside the cache area it can fetch a 10, 25, or 50 mile bubble. The last 8 spots are kept for 30 days. A new download waits for about 10 miles or a new map hex, and 5 minutes. Nothing downloads in Offline Mode.
- Map & Display > Max hex size when zoomed out runs from actual cells to about 19.5 miles (the default). Lower shows more detail when zoomed out. Far zoomed out, edge cells may be hidden so the map stays under 700 shapes.
- The web Install tab explains the Android APK, the Linux build, and Obtainium, and shows what is in the latest release.
- Settings shows whether battery optimization is off for reliable background scanning.

## Other

- Worker area queries accept minLat, maxLat, minLng, and maxLng. Repeated division ids are capped at 32. A radius above 250 miles is sent with those map bounds. An older server still returns at most 250 miles around the point.
- How To Use is updated for the new settings, cache areas, hex size, and background scanning.
- Release notes use the headings Fixes, Enhancements, and Other. See docs/releases/TEMPLATE.md.
- Alpha-19 and later can update from inside the app (Settings > App updates).
- Alpha-17 and Alpha-18 can't update themselves: install this APK once by hand, or use Obtainium.

[Add to Obtainium](https://apps.obtainium.imranr.dev/redirect?r=obtainium://add/https://github.com/mesh-utility/mesh-utility)
