import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:mesh_utility/src/pages/history_page.dart';
import 'package:mesh_utility/src/pages/manual_page.dart';
import 'package:mesh_utility/src/pages/map_page.dart';
import 'package:mesh_utility/src/pages/not_found_page.dart';
import 'package:mesh_utility/src/pages/nodes_page.dart';
import 'package:mesh_utility/src/pages/privacy_page.dart';
import 'package:mesh_utility/src/pages/settings_page.dart';
import 'package:mesh_utility/src/services/app_debug_log_service.dart';
import 'package:mesh_utility/src/services/app_state.dart';
import 'package:mesh_utility/src/services/app_i18n.dart';
import 'package:mesh_utility/src/services/local_store.dart';
import 'package:mesh_utility/src/services/settings_store.dart';
import 'package:mesh_utility/src/widgets/map_page_widgets.dart';
import 'package:mesh_utility/transport/transport.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MeshUtilityApp());
}

class MeshUtilityApp extends StatefulWidget {
  const MeshUtilityApp({super.key});

  @override
  State<MeshUtilityApp> createState() => _MeshUtilityAppState();
}

class _MeshUtilityAppState extends State<MeshUtilityApp> {
  ThemeMode _themeMode = ThemeMode.dark;

  void _toggleTheme() {
    setState(() {
      _themeMode = _themeMode == ThemeMode.dark
          ? ThemeMode.light
          : ThemeMode.dark;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mesh Utility',
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0F766E),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0F766E),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: MeshHomePage(
        onToggleTheme: _toggleTheme,
        darkMode: _themeMode == ThemeMode.dark,
      ),
    );
  }
}

class MeshHomePage extends StatefulWidget {
  const MeshHomePage({
    super.key,
    required this.onToggleTheme,
    required this.darkMode,
  });

  final VoidCallback onToggleTheme;
  final bool darkMode;

  @override
  State<MeshHomePage> createState() => _MeshHomePageState();
}

class _MeshHomePageState extends State<MeshHomePage>
    with WidgetsBindingObserver {
  static const int _statusNotificationId = 1001;
  static const String _statusChannelId = 'radio_status_channel';
  static const String _actionToggleScan = 'toggle_scan';
  static const String _actionForceScan = 'force_scan';

  late final AppState _appState;
  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  final AppDebugLogService _debugLog = AppDebugLogService.instance;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  int _index = 0;
  bool _initialPrivacyDismissedForSession = false;
  bool _initialPrivacyDialogOpen = false;
  bool _requirePrivacyDialogOpen = false;
  String? _historyHexFilter;
  String? _mapFocusHexId;
  String? _mapFocusNodeId;
  bool _resumeScanAfterResume = false;
  bool _notificationsReady = false;
  String _lastStatusNotificationKey = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _appState = AppState(
      settingsStore: SettingsStore(),
      localStore: LocalStore(),
      transport: createDefaultTransport(),
    )..initialize();
    _appState.addListener(_onAppStateChanged);
    _appState.onBlePinRequest = _showBlePinDialog;
    unawaited(_initNotifications());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _appState.removeListener(_onAppStateChanged);
    _appState.onBlePinRequest = null;
    _appState.dispose();
    super.dispose();
  }

  void _onAppStateChanged() {
    unawaited(_syncStatusNotification());
  }

  bool get _isAndroidNative =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> _initNotifications() async {
    if (!_isAndroidNative) return;
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    final initSettings = InitializationSettings(android: androidInit);
    await _notifications.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onNotificationResponse,
    );
    final androidPlugin = _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await androidPlugin?.requestNotificationsPermission();
    _notificationsReady = true;
    await _syncStatusNotification();
  }

  Future<void> _onNotificationResponse(NotificationResponse response) async {
    if (!_isAndroidNative) return;
    switch (response.actionId) {
      case _actionToggleScan:
        if (!_appState.bleConnected) {
          await _appState.connectBle();
        }
        if (_appState.bleConnected) {
          await _appState.toggleBleScan();
        }
        break;
      case _actionForceScan:
        if (!_appState.bleConnected) {
          await _appState.connectBle();
        }
        if (_appState.bleConnected && !_appState.bleBusy) {
          await _appState.forceBleScan();
        }
        break;
      default:
        break;
    }
    await _syncStatusNotification(force: true);
  }

  Future<void> _syncStatusNotification({bool force = false}) async {
    if (!_isAndroidNative || !_notificationsReady) return;
    final show = _appState.bleConnected || _appState.bleScanning;
    if (!show) {
      _lastStatusNotificationKey = '';
      await _notifications.cancel(_statusNotificationId);
      return;
    }

    final radio =
        (_appState.connectedRadioDisplayName ?? _appState.connectedRadioName)
            ?.trim();
    final title = radio == null || radio.isEmpty
        ? 'Radio Status'
        : 'Radio: $radio';
    final status = _appState.bleStatus.trim().isEmpty
        ? (_appState.bleScanning ? 'Scanning' : 'Connected')
        : _appState.bleStatus.trim();
    final key =
        '$title|$status|${_appState.bleScanning}|${_appState.bleBusy}|${_appState.bleConnected}';
    if (!force && key == _lastStatusNotificationKey) return;
    _lastStatusNotificationKey = key;

    final actions = <AndroidNotificationAction>[
      AndroidNotificationAction(
        _actionToggleScan,
        _appState.bleScanning ? 'Pause Scan' : 'Resume Scan',
        showsUserInterface: true,
      ),
      AndroidNotificationAction(
        _actionForceScan,
        'Force Scan',
        showsUserInterface: true,
      ),
    ];
    final details = AndroidNotificationDetails(
      _statusChannelId,
      'Radio Connection Status',
      channelDescription:
          'Shows connected radio and scanning status with quick controls',
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      onlyAlertOnce: true,
      autoCancel: false,
      category: AndroidNotificationCategory.service,
      actions: actions,
    );
    await _notifications.show(
      _statusNotificationId,
      title,
      status,
      NotificationDetails(android: details),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      if (_appState.bleScanning) {
        _resumeScanAfterResume = true;
      }
      _debugLog.info('app_lifecycle', 'App moved to background state=$state');
      return;
    }
    if (state == AppLifecycleState.resumed) {
      _debugLog.info('app_lifecycle', 'App resumed; validating BLE session');
      unawaited(_recoverBleAfterResume());
    }
  }

  Future<void> _recoverBleAfterResume() async {
    if (_appState.bleSelectedDeviceId == null ||
        _appState.bleSelectedDeviceId!.isEmpty) {
      _resumeScanAfterResume = false;
      return;
    }
    if (!_appState.bleConnected) {
      await _appState.connectBle();
    }
    if (_resumeScanAfterResume &&
        _appState.bleConnected &&
        !_appState.bleScanning) {
      _debugLog.info('ble', 'Resuming scan loop after app resume');
      await _appState.toggleBleScan();
    }
    _resumeScanAfterResume = false;
  }

  Future<void> _openUrl(String value) async {
    final uri = Uri.parse(value);
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _shareApp() async {
    const appUrl = 'https://mesh-utility.org/';
    await Clipboard.setData(const ClipboardData(text: appUrl));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Link copied to clipboard')));
    }
  }

  Future<String?> _showBlePinDialog(String deviceId) async {
    if (!mounted) return null;
    return await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        var pinValue = '';
        return AlertDialog(
          title: const Text('Bluetooth Pairing'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Enter PIN/passkey for device $deviceId'),
              const SizedBox(height: 12),
              TextField(
                autofocus: true,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'PIN / Passkey',
                  border: OutlineInputBorder(),
                ),
                onChanged: (value) => pinValue = value,
                onSubmitted: (value) {
                  final submit = value.trim();
                  Navigator.of(context).pop(submit.isEmpty ? null : submit);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final value = pinValue.trim();
                Navigator.of(context).pop(value.isEmpty ? null : value);
              },
              child: const Text('Submit'),
            ),
          ],
        );
      },
    );
  }

  void _maybeShowInitialPrivacyDialog() {
    if (!mounted) return;
    if (_appState.loading) return;
    if (_appState.settings.privacyAccepted) return;
    if (_index == 5) return;
    if (_initialPrivacyDismissedForSession) return;
    if (_initialPrivacyDialogOpen || _requirePrivacyDialogOpen) return;
    _debugLog.info('privacy', 'Showing initial privacy acceptance dialog');
    _initialPrivacyDialogOpen = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final action = await _showPrivacyDialog(initialMode: true);
      if (!mounted) return;
      _initialPrivacyDialogOpen = false;
      _debugLog.info(
        'privacy',
        'Initial privacy dialog result: ${action.name}',
      );
      switch (action) {
        case _PrivacyDialogAction.accept:
          await _appState.updateSettings(
            _appState.settings.copyWith(privacyAccepted: true),
          );
          _debugLog.info(
            'privacy',
            'Privacy policy accepted from initial dialog',
          );
          setState(() {
            _initialPrivacyDismissedForSession = true;
          });
          break;
        case _PrivacyDialogAction.readPolicy:
          _debugLog.info(
            'privacy',
            'Initial privacy dialog requested full privacy page',
          );
          setState(() => _index = 5);
          break;
        case _PrivacyDialogAction.skipOrClose:
          _debugLog.info(
            'privacy',
            'Initial privacy dialog skipped; app remains offline-only',
          );
          setState(() {
            _initialPrivacyDismissedForSession = true;
          });
          break;
      }
    });
  }

  Future<bool> _requirePrivacyAcceptanceForOnline() async {
    if (_appState.settings.privacyAccepted) return true;
    if (_requirePrivacyDialogOpen) return false;
    _debugLog.info(
      'privacy',
      'Online mode requested while privacy not accepted; showing required dialog',
    );
    _requirePrivacyDialogOpen = true;
    final action = await _showPrivacyDialog(initialMode: false);
    _requirePrivacyDialogOpen = false;
    if (!mounted) return false;
    _debugLog.info('privacy', 'Required privacy dialog result: ${action.name}');
    if (action == _PrivacyDialogAction.accept) {
      await _appState.updateSettings(
        _appState.settings.copyWith(privacyAccepted: true, forceOffline: false),
      );
      _debugLog.info(
        'privacy',
        'Privacy policy accepted; online mode unlocked',
      );
      return true;
    }
    if (action == _PrivacyDialogAction.readPolicy) {
      _debugLog.info(
        'privacy',
        'Required privacy dialog requested full privacy page',
      );
      setState(() => _index = 5);
    }
    _debugLog.info(
      'privacy',
      'Online mode remained blocked because privacy was not accepted',
    );
    return false;
  }

  Future<_PrivacyDialogAction> _showPrivacyDialog({
    required bool initialMode,
  }) async {
    final result = await showDialog<_PrivacyDialogAction>(
      context: context,
      barrierDismissible: !initialMode,
      builder: (context) => PopScope(
        canPop: !initialMode,
        child: AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.privacy_tip_outlined, size: 18),
              SizedBox(width: 8),
              Expanded(child: Text('Privacy Policy')),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  initialMode
                      ? 'Please review our privacy policy to continue.'
                      : 'You must accept the privacy policy before switching to online mode.',
                ),
                const SizedBox(height: 10),
                const Text(
                  'Mesh Utility collects location data, radio signal measurements, and device identifiers when you scan. This data is used to build the coverage map and is stored on the server.',
                  style: TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 8),
                const Text(
                  'No account or login is required. The app does not collect personal contact information or use tracking cookies.',
                  style: TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Bluetooth and Location permissions are required for core functionality. Data is also stored locally for offline use.',
                  style: TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => Navigator.of(
                    context,
                  ).pop(_PrivacyDialogAction.readPolicy),
                  child: const Text('Read full privacy policy'),
                ),
              ],
            ),
          ),
          actions: [
            if (initialMode)
              TextButton(
                onPressed: () =>
                    Navigator.of(context).pop(_PrivacyDialogAction.skipOrClose),
                child: const Text('Skip (Offline Only)'),
              )
            else
              TextButton(
                onPressed: () =>
                    Navigator.of(context).pop(_PrivacyDialogAction.skipOrClose),
                child: const Text('Cancel'),
              ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(context).pop(_PrivacyDialogAction.accept),
              child: const Text('I Accept'),
            ),
          ],
        ),
      ),
    );
    return result ?? _PrivacyDialogAction.skipOrClose;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_appState, AppI18n.instance]),
      builder: (context, _) {
        _maybeShowInitialPrivacyDialog();
        final body = _buildPage(_index);
        return LayoutBuilder(
          builder: (context, constraints) {
            final desktop = constraints.maxWidth >= 860;
            final compactHeader = constraints.maxWidth < 520;
            final connectedRadioLabel =
                (_appState.connectedRadioDisplayName ??
                        _appState.connectedRadioName)
                    ?.trim();
            final headerRadioName =
                (connectedRadioLabel != null && connectedRadioLabel.isNotEmpty)
                ? connectedRadioLabel
                : 'Unknown Radio';
            String scanHeaderLabel() {
              if (!_appState.bleConnected) return 'Idle';
              if (!_appState.bleScanning) return 'Paused';
              final liveStatus = _appState.bleStatus.trim();
              if (liveStatus.toLowerCase().contains('smart scan skipped')) {
                return liveStatus;
              }
              if (_appState.bleBusy) {
                switch (_appState.bleScanStatus) {
                  case 'advertising':
                    return 'Advertising';
                  case 'waiting':
                    return 'Waiting';
                  case 'querying':
                    return 'Querying';
                  case 'submitting':
                    return 'Saving';
                  case 'done':
                    return 'Scan Complete';
                  case 'error':
                    return 'Scan Error';
                  default:
                    return 'Scanning';
                }
              }
              if (liveStatus.startsWith('node_discover:') ||
                  liveStatus.startsWith('Discovering')) {
                return liveStatus;
              }
              return 'Scanning';
            }

            final headerStatusText = scanHeaderLabel();
            final headerStatusLower = headerStatusText.toLowerCase();
            final headerStatusIsSmartSkip = headerStatusLower.contains(
              'smart scan skipped',
            );
            final headerStatusColor = headerStatusIsSmartSkip
                ? (Theme.of(context).brightness == Brightness.dark
                      ? const Color(0xFFFFEB3B)
                      : const Color(0xFFB45309))
                : Theme.of(context).textTheme.bodySmall?.color;

            return Scaffold(
              key: _scaffoldKey,
              drawer: desktop
                  ? null
                  : Drawer(
                      child: _AppSidebar(
                        selectedIndex: _index,
                        onSelect: (i) {
                          _debugLog.info(
                            'ui_click',
                            'Sidebar select index=$i (drawer)',
                          );
                          setState(() => _index = i);
                          Navigator.of(context).pop();
                        },
                        onDiscord: () async {
                          await _openUrl('https://discord.gg/Xyhjz7CtuW');
                          if (context.mounted) Navigator.of(context).pop();
                        },
                        onSupport: () async {
                          await _openUrl(
                            'https://www.buymeacoffee.com/Just_Stuff_TM',
                          );
                          if (context.mounted) Navigator.of(context).pop();
                        },
                        onTheme: () {
                          widget.onToggleTheme();
                          Navigator.of(context).pop();
                        },
                        onShare: _shareApp,
                        onPrivacy: () {
                          _debugLog.info(
                            'ui_click',
                            'Sidebar privacy click (drawer)',
                          );
                          setState(() => _index = 5);
                          Navigator.of(context).pop();
                        },
                      ),
                    ),
              body: Row(
                children: [
                  if (desktop)
                    SizedBox(
                      width: 224,
                      child: _AppSidebar(
                        selectedIndex: _index,
                        onSelect: (i) {
                          _debugLog.info(
                            'ui_click',
                            'Sidebar select index=$i (desktop)',
                          );
                          setState(() => _index = i);
                        },
                        onDiscord: () =>
                            _openUrl('https://discord.gg/Xyhjz7CtuW'),
                        onSupport: () => _openUrl(
                          'https://www.buymeacoffee.com/Just_Stuff_TM',
                        ),
                        onTheme: widget.onToggleTheme,
                        onShare: _shareApp,
                        onPrivacy: () {
                          _debugLog.info(
                            'ui_click',
                            'Sidebar privacy click (desktop)',
                          );
                          setState(() => _index = 5);
                        },
                      ),
                    ),
                  Expanded(
                    child: Column(
                      children: [
                        Container(
                          decoration: BoxDecoration(
                            border: Border(
                              bottom: BorderSide(
                                color: Theme.of(context).dividerColor,
                              ),
                            ),
                            color: Theme.of(context).colorScheme.surface,
                          ),
                          child: SafeArea(
                            bottom: false,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              child: Row(
                                children: [
                                  if (!desktop)
                                    IconButton(
                                      onPressed: () {
                                        _debugLog.info(
                                          'ui_click',
                                          'Open drawer menu',
                                        );
                                        _scaffoldKey.currentState?.openDrawer();
                                      },
                                      icon: const Icon(Icons.menu),
                                      tooltip: 'Menu',
                                    ),
                                  if (_appState.settings.forceOffline)
                                    compactHeader
                                        ? const Padding(
                                            padding: EdgeInsets.only(right: 4),
                                            child: Icon(
                                              Icons.wifi_off,
                                              size: 18,
                                            ),
                                          )
                                        : const Padding(
                                            padding: EdgeInsets.only(right: 8),
                                            child: Chip(
                                              avatar: Icon(
                                                Icons.wifi_off,
                                                size: 16,
                                              ),
                                              label: Text('Offline'),
                                            ),
                                          ),
                                  if (_index == 0)
                                    Expanded(
                                      child: SingleChildScrollView(
                                        scrollDirection: Axis.horizontal,
                                        child: Row(
                                          children: [
                                            Container(
                                              margin: const EdgeInsets.only(
                                                right: 6,
                                              ),
                                              padding: EdgeInsets.symmetric(
                                                horizontal: compactHeader
                                                    ? 8
                                                    : 10,
                                                vertical: 5,
                                              ),
                                              decoration: BoxDecoration(
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .surfaceContainerHighest
                                                    .withValues(alpha: 0.35),
                                                borderRadius:
                                                    BorderRadius.circular(999),
                                              ),
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Icon(
                                                    Icons.radio_button_checked,
                                                    size: 10,
                                                    color:
                                                        _appState.bleConnected
                                                        ? const Color(
                                                            0xFF34D399,
                                                          )
                                                        : Colors.grey,
                                                  ),
                                                  const SizedBox(width: 6),
                                                  Text(
                                                    _appState.bleConnected
                                                        ? headerRadioName
                                                        : 'Disconnected',
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .bodySmall
                                                        ?.copyWith(
                                                          fontWeight:
                                                              FontWeight.w600,
                                                        ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            Container(
                                              margin: const EdgeInsets.only(
                                                right: 6,
                                              ),
                                              padding: EdgeInsets.symmetric(
                                                horizontal: compactHeader
                                                    ? 8
                                                    : 10,
                                                vertical: 5,
                                              ),
                                              decoration: BoxDecoration(
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .surfaceContainerHighest
                                                    .withValues(alpha: 0.25),
                                                borderRadius:
                                                    BorderRadius.circular(999),
                                              ),
                                              child: SizedBox(
                                                width: compactHeader
                                                    ? 132
                                                    : 220,
                                                child: OverflowMarqueeText(
                                                  text: headerStatusText,
                                                  pixelsPerSecond: 34,
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .bodySmall
                                                      ?.copyWith(
                                                        color:
                                                            headerStatusColor,
                                                        fontWeight:
                                                            headerStatusIsSmartSkip
                                                            ? FontWeight.w700
                                                            : FontWeight.w600,
                                                      ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    )
                                  else
                                    const Spacer(),
                                ],
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: Stack(
                            children: [
                              Positioned.fill(child: body),
                              if (_appState.error != null)
                                Positioned(
                                  left: 12,
                                  right: 12,
                                  bottom: 12,
                                  child: Card(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.errorContainer,
                                    child: Padding(
                                      padding: const EdgeInsets.all(12),
                                      child: Text(
                                        _appState.error!,
                                        style: TextStyle(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onErrorContainer,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildPage(int index) {
    if (_appState.loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final resolvedNodeNames = <String, String>{};
    for (final node in _appState.nodes) {
      final name = node.name?.trim();
      if (name != null && name.isNotEmpty) {
        resolvedNodeNames[node.nodeId] = name;
      }
    }
    for (final entry in _appState.knownContactNames.entries) {
      final id = entry.key.trim();
      final name = entry.value.trim();
      if (id.isEmpty || name.isEmpty) continue;
      final existing = (resolvedNodeNames[id] ?? '').trim();
      if (existing.isEmpty || _looksLikeIdLabel(existing)) {
        resolvedNodeNames[id] = name;
      } else {
        resolvedNodeNames.putIfAbsent(id, () => name);
      }
    }

    switch (index) {
      case 0:
        final observer = _latestObserverPosition();
        return MapPage(
          zones: _appState.coverageZones,
          onRefresh: _appState.syncFromWorker,
          syncing: _appState.syncing,
          forceOffline: _appState.settings.forceOffline,
          bleConnected: _appState.bleConnected,
          bleBusy:
              _appState.bleBusy ||
              _appState.bleConnecting ||
              _appState.bleDeviceScanInProgress,
          bleStatus: _appState.bleStatus,
          bleScanning: _appState.bleScanning,
          bleScanStatus: _appState.bleScanStatus,
          bleDiscoveries: _appState.bleDiscoveries.length,
          bleNextScanCountdown: _appState.bleNextScanCountdown,
          bleLastDiscoverAt: _appState.bleLastDiscoverAt,
          bleLastDiscoverCount: _appState.bleLastDiscoverCount,
          bleLastDiscoverError: _appState.bleLastDiscoverError,
          autoCenter: _appState.settings.autoCenter,
          onToggleAutoCenter: _appState.setAutoCenter,
          onBleConnect: _appState.connectBle,
          onBleDisconnect: _appState.disconnectBle,
          onBleNodeDiscover: _appState.forceBleScan,
          onBleToggleScan: _appState.toggleBleScan,
          onOpenHistoryFromZone: (zoneId) {
            _debugLog.info('ui_click', 'Map -> History from zone=$zoneId');
            setState(() {
              _historyHexFilter = zoneId;
              _index = 2;
            });
          },
          focusHexId: _mapFocusHexId,
          focusNodeId: _mapFocusNodeId,
          resolvedNodeNames: resolvedNodeNames,
          scans: _appState.scanResults,
          rawScans: _appState.rawScans,
          nodesCount: _appState.nodes.length,
          statsRadiusMiles: _appState.settings.statsRadiusMiles,
          unitSystem: _appState.settings.unitSystem,
          observerLat: observer?.$1,
          observerLng: observer?.$2,
          connectedRadioName: _appState.connectedRadioDisplayName,
          connectedRadioMeshId: _appState.connectedRadioMeshId8,
        );
      case 1:
        return NodesPage(
          nodes: _appState.nodes,
          scanResults: _appState.scanResults,
          onOpenMapForNode: (nodeId) {
            _debugLog.info('ui_click', 'Nodes -> Map for node=$nodeId');
            setState(() {
              _mapFocusNodeId = nodeId;
              _index = 0;
            });
          },
        );
      case 2:
        return HistoryPage(
          scans: _appState.scanResults,
          initialHexId: _historyHexFilter,
          unitSystem: _appState.settings.unitSystem,
          resolvedNodeNames: resolvedNodeNames,
          connectedRadioName: _appState.connectedRadioDisplayName,
          connectedRadioMeshId: _appState.connectedRadioMeshId8,
          onOpenMapFromHex: (hexId) {
            _debugLog.info('ui_click', 'History -> Map for hex=$hexId');
            setState(() {
              _mapFocusHexId = hexId;
              _index = 0;
            });
          },
        );
      case 3:
        return const ManualPage();
      case 4:
        return SettingsPage(
          settings: _appState.settings,
          syncing: _appState.syncing,
          localScanCount: _appState.localScanCount,
          uploadQueueCount: _appState.uploadQueueCount,
          lastSyncAt: _appState.lastSyncAt,
          lastSyncScanCount: _appState.lastSyncScanCount,
          bleConnected: _appState.bleConnected,
          bleBusy: _appState.bleBusy || _appState.bleConnecting,
          bleStatus: _appState.bleStatus,
          bleScanDevices: _appState.bleScanDevices,
          bleSelectedDeviceId: _appState.bleSelectedDeviceId,
          onSelectBleDevice: _appState.selectBleDevice,
          onScanBleDevices: _appState.scanBleDevices,
          debugLogs: _appState.debugLogs,
          onClearDebugLogs: _appState.clearDebugLogs,
          onClearScanCache: _appState.clearScanCache,
          onChanged: (value) async {
            final wantsOnline =
                _appState.settings.forceOffline && !value.forceOffline;
            if (wantsOnline && !_appState.settings.privacyAccepted) {
              _debugLog.info(
                'privacy',
                'Settings requested online mode while privacy not accepted',
              );
              final accepted = await _requirePrivacyAcceptanceForOnline();
              if (!accepted) return;
              await _appState.updateSettings(
                value.copyWith(privacyAccepted: true, forceOffline: false),
              );
              _debugLog.info(
                'privacy',
                'Settings online mode enabled after privacy acceptance',
              );
              return;
            }
            if (_appState.settings.forceOffline != value.forceOffline) {
              _debugLog.info(
                'privacy',
                value.forceOffline
                    ? 'Settings switched to offline mode'
                    : 'Settings switched to online mode',
              );
            }
            await _appState.updateSettings(value);
          },
          onSync: _appState.syncFromWorker,
          onBleConnect: _appState.connectBle,
          onBleDisconnect: _appState.disconnectBle,
          onBleNodeDiscover: _appState.runNodeDiscover,
        );
      case 5:
        return const PrivacyPage();
      default:
        return const NotFoundPage();
    }
  }

  (double, double)? _latestObserverPosition() {
    return _appState.currentObserverPosition;
  }

  bool _looksLikeIdLabel(String value) {
    final normalized = value.trim().toUpperCase();
    if (normalized.isEmpty) return false;
    if (normalized.contains(':')) return true;
    final hexOnly = normalized.replaceAll(RegExp(r'[^0-9A-F]'), '');
    return hexOnly.length == normalized.length && hexOnly.length >= 8;
  }
}

enum _PrivacyDialogAction { accept, skipOrClose, readPolicy }

class _AppSidebar extends StatelessWidget {
  const _AppSidebar({
    required this.selectedIndex,
    required this.onSelect,
    required this.onDiscord,
    required this.onSupport,
    required this.onTheme,
    required this.onShare,
    required this.onPrivacy,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final Future<void> Function() onDiscord;
  final Future<void> Function() onSupport;
  final VoidCallback onTheme;
  final VoidCallback onShare;
  final VoidCallback onPrivacy;

  @override
  Widget build(BuildContext context) {
    final i18n = AppI18n.instance;
    return Container(
      decoration: BoxDecoration(
        border: Border(
          right: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.asset(
                    'assets/app-icon.png',
                    width: 36,
                    height: 36,
                    fit: BoxFit.cover,
                  ),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Mesh Utility',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      SizedBox(height: 2),
                      Text('LoRa MeshCore', style: TextStyle(fontSize: 11)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Text(
              i18n.t('nav.navigation'),
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(height: 8),
          _NavButton(
            label: i18n.t('nav.coverageMap'),
            icon: Icons.map_outlined,
            selected: selectedIndex == 0,
            onTap: () => onSelect(0),
          ),
          _NavButton(
            label: i18n.t('settings.title'),
            icon: Icons.settings_outlined,
            selected: selectedIndex == 4,
            onTap: () => onSelect(4),
          ),
          _NavButton(
            label: i18n.t('nav.nodes'),
            icon: Icons.settings_input_antenna,
            selected: selectedIndex == 1,
            onTap: () => onSelect(1),
          ),
          _NavButton(
            label: i18n.t('nav.scanHistory'),
            icon: Icons.stacked_line_chart,
            selected: selectedIndex == 2,
            onTap: () => onSelect(2),
          ),
          _NavButton(
            label: i18n.t('nav.howToUse'),
            icon: Icons.help_outline,
            selected: selectedIndex == 3,
            onTap: () => onSelect(3),
          ),
          _NavButton(
            label: 'Discord',
            icon: Icons.forum_outlined,
            selected: false,
            onTap: () {
              onDiscord();
            },
          ),
          _NavButton(
            label: 'Support Development',
            icon: Icons.coffee_outlined,
            selected: false,
            onTap: () {
              onSupport();
            },
          ),
          _NavButton(
            label: 'Theme',
            icon: Icons.dark_mode_outlined,
            selected: false,
            onTap: onTheme,
          ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                OutlinedButton.icon(
                  onPressed: onShare,
                  icon: const Icon(Icons.share, size: 16),
                  label: const Text('Share App'),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: onPrivacy,
                  icon: const Icon(Icons.privacy_tip_outlined, size: 14),
                  label: Text(i18n.t('nav.privacyPolicy')),
                ),
                const SizedBox(height: 6),
                const Center(
                  child: Text(
                    'Mesh Utility v1.2',
                    style: TextStyle(fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected
        ? Theme.of(context).colorScheme.primaryContainer
        : Colors.transparent;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Material(
        color: color,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(icon, size: 18),
                const SizedBox(width: 10),
                Text(label),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
