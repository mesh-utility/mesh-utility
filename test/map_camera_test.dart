import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_utility/src/services/map_camera.dart';

void main() {
  test('a visitor with no own fix opens on the contiguous US', () {
    final camera = initialMapCamera(ownLatitude: null, ownLongitude: null);

    expect(camera.latitude, neutralMapLatitude);
    expect(camera.longitude, neutralMapLongitude);
    expect(camera.latitude, 39.5);
    expect(camera.longitude, -98.35);
    expect(camera.zoom, neutralMapZoom);
    expect(camera.zoom, 4);
  });

  test('coverage zones and foreign scans cannot choose the opening camera', () {
    // initialMapCamera takes only this device's fix. A Pennsylvania scan or
    // the first coverage zone is not an argument, so it cannot move the map.
    final camera = initialMapCamera(ownLatitude: null, ownLongitude: null);

    expect(camera.latitude, neutralMapLatitude);
    expect(camera.longitude, lessThan(-90));
    expect(camera.zoom, neutralMapZoom);
  });

  test('an own fix opens centered on that fix', () {
    final camera = initialMapCamera(ownLatitude: 37.2, ownLongitude: -122.1);

    expect(camera.latitude, 37.2);
    expect(camera.longitude, -122.1);
    expect(camera.zoom, ownFixMapZoom);
  });

  test('an unusable fix stays on the general view', () {
    final camera = initialMapCamera(
      ownLatitude: double.nan,
      ownLongitude: -98.35,
    );

    expect(camera.latitude, neutralMapLatitude);
    expect(camera.longitude, neutralMapLongitude);
    expect(camera.zoom, neutralMapZoom);
  });

  test('live GPS wins over a stored fix', () {
    final fix = ownDeviceMapFix(
      deviceLatitude: 37.2,
      deviceLongitude: -122.1,
      storedLatitude: 40.05,
      storedLongitude: -75.4,
      allowStoredFix: true,
    );

    expect(fix, (37.2, -122.1));
  });

  test('the native app may use its own stored GPS fix', () {
    final fix = ownDeviceMapFix(
      deviceLatitude: null,
      deviceLongitude: null,
      storedLatitude: 37.2,
      storedLongitude: -122.1,
      allowStoredFix: true,
    );

    expect(fix, (37.2, -122.1));
  });

  test('the web visitor ignores a stored fix and any foreign point', () {
    final fix = ownDeviceMapFix(
      deviceLatitude: null,
      deviceLongitude: null,
      storedLatitude: 40.05,
      storedLongitude: -75.4,
      allowStoredFix: false,
    );

    expect(fix, isNull);
    expect(
      initialMapCamera(ownLatitude: fix?.$1, ownLongitude: fix?.$2).zoom,
      neutralMapZoom,
    );
  });

  test('no device fix means no map position', () {
    expect(
      ownDeviceMapFix(
        deviceLatitude: null,
        deviceLongitude: null,
        storedLatitude: null,
        storedLongitude: null,
        allowStoredFix: true,
      ),
      isNull,
    );
  });

  test('a stored fix outside the valid range is ignored', () {
    expect(
      ownDeviceMapFix(
        deviceLatitude: null,
        deviceLongitude: null,
        storedLatitude: 120,
        storedLongitude: -75,
        allowStoredFix: true,
      ),
      isNull,
    );
  });

  test('the first own fix from the general view zooms in', () {
    expect(
      zoomAfterOwnFixArrives(currentZoom: 4, alreadyCenteredOnOwnFix: false),
      ownFixMapZoom,
    );
    expect(
      zoomAfterOwnFixArrives(currentZoom: 4, alreadyCenteredOnOwnFix: true),
      4,
    );
    expect(
      zoomAfterOwnFixArrives(currentZoom: 12, alreadyCenteredOnOwnFix: false),
      12,
    );
  });
}
