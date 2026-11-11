# Mesh Utility Alpha-25.2

## Fixes

- The Nodes list now shows only mesh nodes that were heard. Observer radios no longer appear there. History and hex popups still show who observed a cell.
- Tapping a node in the Nodes list again zooms to and filters that node’s coverage hexes.
- Hexes now stay locked to their map location while zooming and rotating.
- Coverage hexes stay on the fixed grid. Cells are not resized, merged, or moved when you zoom, and the max hex size slider has been removed.
- Every Cloud History day range works with the on-demand coverage index. Zooming all the way out on Global shows the full map.
- Tapping a hex opens a full popup with node names, who observed them, and scan counts.
- Scan History and the Nodes list work for any cache area, including Global.
- Swiping the app away disconnects and releases the radio so another app can use it. If the radio is already in use by another app, you get a clear notice instead of a silent failure.
- Opening the app again no longer starts a second instance.
- Force scan works while the scan loop is running.
- Contacts sync no longer stalls partway through.
- Repeater names that had been overwritten are restored, and a good name is no longer replaced with a blank or placeholder.
- The connected radio shows its own name from the radio itself, not the name of a contact that looks similar.
- Apostrophes and other punctuation in radio and repeater names are kept.

## Enhancements

## Other

- The Download where I travel option has been removed. Coverage downloads follow the Scan cache area you pick in Settings.
- Alpha-19 and later can update from inside the app (Settings > App updates).
- Alpha-17 and Alpha-18 can't update themselves: install this APK once by hand, or use Obtainium.

[Add to Obtainium](https://apps.obtainium.imranr.dev/redirect?r=obtainium://add/https://github.com/mesh-utility/mesh-utility)
