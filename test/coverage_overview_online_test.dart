import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mesh_utility/src/services/app_state.dart';
import 'package:mesh_utility/src/services/coverage_overview.dart';
import 'package:mesh_utility/src/services/local_store.dart';
import 'package:mesh_utility/src/services/settings_store.dart';
import 'package:mesh_utility/src/services/worker_api.dart';
import 'package:mesh_utility/transport/transport_core.dart';

class _MemorySettingsStore extends SettingsStore {
  _MemorySettingsStore(this.value);

  AppSettings value;

  @override
  Future<AppSettings> load() async => value;

  @override
  Future<void> save(AppSettings settings) async {
    value = settings;
  }
}

class _FakeTransport extends Transport {
  _FakeTransport() : super('fake');

  @override
  bool get isConnected => false;

  @override
  Stream<Uint8List> get inbound => const Stream<Uint8List>.empty();

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> send(Uint8List payload) async {}

  @override
  Future<void> dispose() async {}
}

void main() {
  const headers = {'content-type': 'application/json'};
  const body = {
    'generatedDay': '2026-11-09',
    'scale': 256,
    'cells': [
      {'id': '152:-209', 's': 4, 'r': 0, 'n': 1},
    ],
  };

  test(
    'accepting privacy or turning online fetches general coverage',
    () async {
      final requests = <Uri>[];
      Object? stored;
      final settings = _MemorySettingsStore(
        AppSettings.defaults.copyWith(
          privacyAccepted: false,
          forceOffline: true,
          privacyForceOfflineMigrated: true,
        ),
      );
      final state = AppState(
        settingsStore: settings,
        localStore: LocalStore(),
        transport: _FakeTransport(),
        coverageOverviewCache: CoverageOverviewCache(
          read: () async => stored,
          write: (value) async {
            stored = value;
          },
        ),
        coverageOverviewApi: () => WorkerApi(
          'https://worker.example',
          httpGet: (uri) async {
            requests.add(uri);
            return http.Response(jsonEncode(body), 200, headers: headers);
          },
        ),
      );
      state.settings = settings.value;
      addTearDown(state.dispose);

      await state.updateSettings(
        state.settings.copyWith(discoverWaitSeconds: 12),
      );
      await _settle();
      expect(requests, isEmpty, reason: 'staying offline must not fetch');
      expect(state.settings.forceOffline, isTrue);

      await state.updateSettings(
        state.settings.copyWith(privacyAccepted: true, forceOffline: false),
      );
      await _settle();
      expect(requests, hasLength(1));
      expect(requests.single.path, '/coverage/overview');
      expect(state.settings.privacyAccepted, isTrue);
      expect(state.settings.forceOffline, isFalse);
      expect(state.coverageOverviewCells.single.id, '152:-209');

      await state.updateSettings(state.settings.copyWith(forceOffline: true));
      final afterOffline = requests.length;
      await state.updateSettings(state.settings.copyWith(forceOffline: false));
      await _settle();
      expect(requests, hasLength(afterOffline));
      expect(
        state.coverageOverviewCells.single.id,
        '152:-209',
        reason: 'a fresh cached overview is kept when coming back online',
      );
    },
  );
}

Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
