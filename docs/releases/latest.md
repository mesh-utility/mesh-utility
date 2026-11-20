# Mesh Utility Alpha-26.1

## Fixes

- The web map no longer freezes when you pan or zoom with lots of coverage on screen.
- The map pans and zooms more smoothly, even with thousands of hexes on screen.
- Map tiles load reliably at every zoom level. Zooming in past the most detailed tiles now enlarges them instead of showing a blank map.
- Tapping a node in the Nodes list no longer zooms past the map tiles and leaves a blank map.
- Hex popups show who observed the cell and the SNR in, matching Scan History.
- The Nodes count on the map stats bar now counts the nodes heard in the hexes on the map, and shows a small radio icon for whether a radio is connected.
- Automatic sync now honors the sync interval in Settings (30 minutes by default) instead of syncing every minute.
- The map legend matches what is drawn: signal colors, dead zones (gray outline, faint fill), and your location dot.
- The Nodes list now shows only mesh nodes that were heard. Observer radios no longer appear there. History and hex popups still show who observed a cell.
- Tapping a node in the Nodes list again zooms to and filters that node’s coverage hexes.
- Hexes now stay locked to their map location while zooming and rotating.
- Coverage hexes stay on the fixed grid. Cells are not resized, merged, or moved when you zoom, and the max hex size slider has been removed.
- Every Cloud History day range works with the on-demand coverage index. Zooming all the way out on Global shows the full map.
- Tapping a hex opens a full popup with node names, who observed them, and scan counts.
- Scan History and the Nodes list work for any cache area, including Global.
- Swiping the app away disconnects and releases the radio so another app can use it. If the radio is already in use by another app, you get a clear notice instead of a silent failure.
- Leaving the app with Home or Back keeps it running and connected to your radio.
- Opening the app again no longer starts a second instance.
- Force scan works while the scan loop is running.
- Contacts sync no longer stalls partway through.
- Repeater names that had been overwritten are restored, and a good name is no longer replaced with a blank or placeholder.
- The connected radio shows its own name from the radio itself, not the name of a contact that looks similar.
- Apostrophes and other punctuation in radio and repeater names are kept.

## Enhancements

## Other

- Settings help text is shorter and easier to read.
- The Download where I travel option has been removed. The map shows coverage for the Scan cache area you pick in Settings.
- Alpha-19 and later can update from inside the app (Settings > App updates).
- Alpha-17 and Alpha-18 can't update themselves: install this APK once by hand, or use Obtainium.

[Add to Obtainium](https://apps.obtainium.imranr.dev/redirect?r=obtainium://add/https://github.com/mesh-utility/mesh-utility)
