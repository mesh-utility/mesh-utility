// Opening view of the coverage map, and the only positions allowed to move it.
// Zone centers, scan coordinates, and anything returned by the server are
// not inputs. A visitor who has not shared this device's location stays on
// the general view.

const double neutralMapLatitude = 39.5;
const double neutralMapLongitude = -98.35;
const double neutralMapZoom = 4;
const double ownFixMapZoom = 10;

class MapCameraStart {
  const MapCameraStart({
    required this.latitude,
    required this.longitude,
    required this.zoom,
  });

  final double latitude;
  final double longitude;
  final double zoom;
}

bool isUsableMapFix(double? latitude, double? longitude) {
  if (latitude == null || longitude == null) return false;
  if (!latitude.isFinite || !longitude.isFinite) return false;
  if (latitude < -90 || latitude > 90) return false;
  if (longitude < -180 || longitude > 180) return false;
  return true;
}

/// Camera used the first time the map is built.
///
/// [ownLatitude] and [ownLongitude] are this device's own fix. There is no
/// parameter for zones, scans, or a server position.
MapCameraStart initialMapCamera({
  required double? ownLatitude,
  required double? ownLongitude,
}) {
  if (isUsableMapFix(ownLatitude, ownLongitude)) {
    return MapCameraStart(
      latitude: ownLatitude!,
      longitude: ownLongitude!,
      zoom: ownFixMapZoom,
    );
  }
  return const MapCameraStart(
    latitude: neutralMapLatitude,
    longitude: neutralMapLongitude,
    zoom: neutralMapZoom,
  );
}

/// Position the map may treat as this device.
///
/// A live GPS fix wins. [storedLatitude] and [storedLongitude] are a fix this
/// same device saved from its own GPS. They are used only when
/// [allowStoredFix] is true (the native app). The web visitor ignores them.
/// Scan rows and server payloads are not accepted.
(double latitude, double longitude)? ownDeviceMapFix({
  required double? deviceLatitude,
  required double? deviceLongitude,
  required double? storedLatitude,
  required double? storedLongitude,
  required bool allowStoredFix,
}) {
  if (isUsableMapFix(deviceLatitude, deviceLongitude)) {
    return (deviceLatitude!, deviceLongitude!);
  }
  if (allowStoredFix && isUsableMapFix(storedLatitude, storedLongitude)) {
    return (storedLatitude!, storedLongitude!);
  }
  return null;
}

/// Zoom to use when auto-center moves onto an own fix.
///
/// The first lock from the general view zooms in. A later GPS tick keeps
/// whatever zoom the camera already has.
double zoomAfterOwnFixArrives({
  required double currentZoom,
  required bool alreadyCenteredOnOwnFix,
}) {
  if (!alreadyCenteredOnOwnFix && currentZoom <= neutralMapZoom + 0.05) {
    return ownFixMapZoom;
  }
  return currentZoom;
}
