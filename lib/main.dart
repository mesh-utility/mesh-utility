import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:mesh_utility/src/pages/connections_page.dart';
import 'package:mesh_utility/src/pages/history_page.dart';
import 'package:mesh_utility/src/pages/manual_page.dart';
import 'package:mesh_utility/src/pages/map_page.dart';
import 'package:mesh_utility/src/pages/not_found_page.dart';
import 'package:mesh_utility/src/pages/nodes_page.dart';
import 'package:mesh_utility/src/pages/privacy_page.dart';
import 'package:mesh_utility/src/pages/settings_page.dart';
import 'package:mesh_utility/src/pages/contacts_page.dart';
import 'package:mesh_utility/src/services/app_debug_log_service.dart';
import 'package:mesh_utility/src/services/app_state.dart';
import 'package:mesh_utility/src/services/app_i18n.dart';
import 'package:mesh_utility/src/services/local_store.dart';
import 'package:mesh_utility/src/services/settings_store.dart';
import 'package:mesh_utility/src/widgets/map_page_widgets.dart';
import 'package:mesh_utility/transport/transport.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:universal_ble/universal_ble.dart';
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

  ThemeData _buildTheme(Brightness brightness) {
    final base = ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF2563EB),
        brightness: brightness,
      ),
      useMaterial3: true,
      visualDensity: VisualDensity.standard,
    );
    final textTheme = base.textTheme
        .copyWith(
          bodyLarge: base.textTheme.bodyLarge?.copyWith(
            fontSize: 17,
            height: 1.35,
          ),
          bodyMedium: base.textTheme.bodyMedium?.copyWith(
            fontSize: 15.5,
            height: 1.35,
          ),
          bodySmall: base.textTheme.bodySmall?.copyWith(
            fontSize: 13.5,
            height: 1.3,
          ),
          titleMedium: base.textTheme.titleMedium?.copyWith(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            height: 1.25,
          ),
          titleLarge: base.textTheme.titleLarge?.copyWith(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            height: 1.2,
          ),
          labelLarge: base.textTheme.labelLarge?.copyWith(
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        )
        .apply(
          bodyColor: base.colorScheme.onSurface,
          displayColor: base.colorScheme.onSurface,
        );

    return base.copyWith(
      textTheme: textTheme,
      appBarTheme: AppBarTheme(titleTextStyle: textTheme.titleMedium),
      cardTheme: CardThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        elevation: 1,
      ),
      chipTheme: base.chipTheme.copyWith(
        labelStyle: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      ),
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        titleTextStyle: textTheme.bodyLarge?.copyWith(
          fontWeight: FontWeight.w600,
        ),
        subtitleTextStyle: textTheme.bodyMedium,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: base.colorScheme.surfaceContainerHighest.withValues(
          alpha: brightness == Brightness.dark ? 0.24 : 0.5,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
        labelStyle: textTheme.bodyMedium?.copyWith(
          fontWeight: FontWeight.w600,
          color: base.colorScheme.onSurface,
        ),
        floatingLabelStyle: textTheme.bodySmall?.copyWith(
          fontWeight: FontWeight.w700,
          color: base.colorScheme.primary,
        ),
        border: const OutlineInputBorder(),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          minimumSize: const Size(96, 44),
          textStyle: textTheme.labelLarge,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(96, 44),
          textStyle: textTheme.labelLarge,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(96, 44),
          textStyle: textTheme.labelLarge,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mesh Utility',
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      theme: _buildTheme(Brightness.light),
      darkTheme: _buildTheme(Brightness.dark),
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
  static const MethodChannel _settingsChannel = MethodChannel(
    'org.meshutility.app/settings',
  );

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
  bool _enteredBackground = false;
  bool _notificationsReady = false;
  bool _bleUnavailableDialogOpen = false;
  String _lastStatusNotificationKey = '';
  bool? _portraitLockActive;
  static const double _tabletShortestSideDp = 600.0;
  bool _startupNavResolved = false;
  bool _startupRoutedToConnections = false;
  bool _previousBleConnected = false;

  /// Navigate to a page index, auto-triggering a BLE scan when arriving at
  /// the Connections page (index 1) if not already connected.
  void _navigateTo(int index) {
    setState(() => _index = index);
    if (index == 1 && !_appState.bleConnected && !_appState.bleConnecting) {
      unawaited(_appState.scanBleDevices());
    }
  }

  String _formatScanProgressStatus(String base) {
    final count = _appState.bleDiscoveries.length;
    if (count <= 0) return base;
    final countLabel = '$count ${count == 1 ? 'repeater' : 'repeaters'}';
    return '$base · $countLabel';
  }

  String? _headerCountdownLabel() {
    if (_appState.settings.smartScanEnabled) return null;
    if (!_appState.bleScanning) return null;
    final seconds = _appState.bleNextScanCountdown;
    if (seconds == null || seconds < 0) return null;
    final mm = (seconds ~/ 60).toString().padLeft(2, '0');
    final ss = (seconds % 60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_updateOrientationLock());
    _appState = AppState(
      settingsStore: SettingsStore(),
      localStore: LocalStore(),
      transport: createDefaultTransport(),
    )..initialize();
    _appState.addListener(_onAppStateChanged);
    _appState.onBlePinRequest = _showBlePinDialog;
    _appState.onLocationPermissionPrompt = _showLocationPermissionDialog;
    _appState.onBleUnavailablePrompt = _showBleUnavailableDialog;
    unawaited(_initNotifications());
  }

  @override
  void dispose() {
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)) {
      unawaited(
        SystemChrome.setPreferredOrientations(DeviceOrientation.values),
      );
    }
    WidgetsBinding.instance.removeObserver(this);
    _appState.removeListener(_onAppStateChanged);
    _appState.onBlePinRequest = null;
    _appState.onLocationPermissionPrompt = null;
    _appState.onBleUnavailablePrompt = null;
    _appState.dispose();
    super.dispose();
  }

  Future<T?> _showPromptPage<T>({required Widget child, bool canPop = true}) {
    if (!mounted) return Future<T?>.value(null);
    return Navigator.of(context).push<T>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _PromptPageShell(canPop: canPop, child: child),
      ),
    );
  }

  Future<void> _showBleUnavailableDialog({
    required AvailabilityState state,
    required String context,
  }) async {
    if (kIsWeb || !mounted) return;
    if (_bleUnavailableDialogOpen) return;
    if (state == AvailabilityState.poweredOn ||
        state == AvailabilityState.unsupported) {
      return;
    }
    _bleUnavailableDialogOpen = true;
    try {
      await Future<void>.delayed(Duration.zero);
      if (!mounted) return;
      final title = switch (state) {
        AvailabilityState.poweredOff => 'Turn Bluetooth On',
        AvailabilityState.unauthorized => 'Allow Bluetooth Access',
        AvailabilityState.resetting => 'Bluetooth Resetting',
        _ => 'Bluetooth Unavailable',
      };
      final message = switch (state) {
        AvailabilityState.poweredOff =>
          'Bluetooth is currently off. Turn it on to scan and connect to radios.',
        AvailabilityState.unauthorized =>
          'Bluetooth permission is blocked for Mesh Utility. Allow Bluetooth access in Android settings, then try again.',
        AvailabilityState.resetting =>
          'Bluetooth is resetting right now. Wait a moment, then try again.',
        _ =>
          'Bluetooth is unavailable right now. Check your device settings and retry.',
      };
      final canOpenSettings =
          !kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.iOS);
      final openSettings = await _showPromptPage<bool>(
        child: Builder(
          builder: (pageContext) => _PromptCard(
            title: Text(title),
            content: Text(message),
            actions: [
              if (canOpenSettings)
                TextButton(
                  onPressed: () => Navigator.of(pageContext).pop(false),
                  child: const Text('Not now'),
                ),
              FilledButton(
                onPressed: () => Navigator.of(pageContext).pop(canOpenSettings),
                child: Text(canOpenSettings ? 'Open Settings' : 'OK'),
              ),
            ],
          ),
        ),
      );
      if (canOpenSettings && openSettings == true) {
        if (_isAndroidNative && state == AvailabilityState.poweredOff) {
          final opened = await _openAndroidBluetoothSettings();
          if (!opened) {
            await ph.openAppSettings();
          }
        } else {
          await ph.openAppSettings();
        }
      }
      _debugLog.info('ble', 'BLE prompt shown state=$state context=$context');
    } finally {
      _bleUnavailableDialogOpen = false;
    }
  }

  Future<bool> _openAndroidBluetoothSettings() async {
    if (!_isAndroidNative) return false;
    try {
      final opened =
          await _settingsChannel.invokeMethod<bool>('openBluetoothSettings') ??
          false;
      _debugLog.info(
        'ble',
        'Requested Android Bluetooth settings opened=$opened',
      );
      return opened;
    } catch (e) {
      _debugLog.warn('ble', 'Failed opening Android Bluetooth settings: $e');
      return false;
    }
  }

  Future<bool> _showLocationPermissionDialog({required bool background}) async {
    if (!_isAndroidNative || !mounted) return true;
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return false;
    final title = background
        ? 'Allow Background Location'
        : 'Allow Location Access';
    final content = background
        ? 'Mesh Utility needs background location so scans and radio features '
              'continue reliably when the app is not in the foreground. '
              'Android will now show the system background-location prompt.'
        : 'Mesh Utility needs location access to map coverage and support BLE '
              'scanning. Android will now show the system location prompt.';
    final result = await _showPromptPage<bool>(
      canPop: false,
      child: Builder(
        builder: (pageContext) => _PromptCard(
          title: Text(title),
          content: Text(content),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(pageContext).pop(false),
              child: const Text('Not now'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(pageContext).pop(true),
              child: const Text('Continue'),
            ),
          ],
        ),
      ),
    );
    return result ?? false;
  }

  void _onAppStateChanged() {
    if (!_startupNavResolved && !_appState.loading) {
      _startupNavResolved = true;
      if (!_appState.bleConnected && _index == 0) {
        _startupRoutedToConnections = true;
        _navigateTo(1);
      }
    }
    if (_startupRoutedToConnections && _appState.bleConnected) {
      _startupRoutedToConnections = false;
      if (_index != 0) {
        _debugLog.info(
          'ui_nav',
          'Startup BLE connect succeeded; navigating to Coverage Map',
        );
        setState(() => _index = 0);
      }
      _showConnectedSnackBar();
    }
    if (!_previousBleConnected && _appState.bleConnected) {
      _showConnectedSnackBar();
    }
    _previousBleConnected = _appState.bleConnected;
    unawaited(_syncStatusNotification());
  }

  bool get _isAndroidNative =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> _updateOrientationLock() async {
    if (kIsWeb) return;
    final target = defaultTargetPlatform;
    final isMobile =
        target == TargetPlatform.android || target == TargetPlatform.iOS;
    if (!isMobile) {
      if (_portraitLockActive != false) {
        await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
        _portraitLockActive = false;
      }
      return;
    }

    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return;
    final view = views.first;
    final dpr = view.devicePixelRatio;
    final size = view.physicalSize;
    if (dpr <= 0 || size.isEmpty) return;

    final shortestDp = size.shortestSide / dpr;
    final lockPortrait = shortestDp < _tabletShortestSideDp;
    if (_portraitLockActive == lockPortrait) return;

    await SystemChrome.setPreferredOrientations(
      lockPortrait
          ? const [DeviceOrientation.portraitUp]
          : DeviceOrientation.values,
    );
    _portraitLockActive = lockPortrait;
  }

  Future<void> _initNotifications() async {
    if (!_isAndroidNative) return;
    try {
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
    } catch (e) {
      _notificationsReady = false;
      _debugLog.warn('notifications', 'Notification init skipped: $e');
    }
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
        ? (_appState.bleScanning ? 'Discovery Sent' : 'Connected')
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
    final linuxInactiveFocusChange =
        !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.linux &&
        state == AppLifecycleState.inactive;
    if (linuxInactiveFocusChange) {
      _debugLog.info(
        'app_lifecycle',
        'Linux inactive focus change; keeping background activity state unchanged',
      );
      return;
    }
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      if (state == AppLifecycleState.detached) {
        _appState.markHostDetaching();
      }
      if (_appState.bleScanning) {
        _resumeScanAfterResume = true;
      }
      _enteredBackground = true;
      if (state == AppLifecycleState.inactive) {
        _debugLog.info(
          'app_lifecycle',
          'App inactive (focus loss or transient system UI), state=$state',
        );
      } else {
        _debugLog.info('app_lifecycle', 'App moved to background state=$state');
      }
      return;
    }
    if (state == AppLifecycleState.resumed) {
      if (!_enteredBackground) {
        _debugLog.info(
          'app_lifecycle',
          'App resumed without background transition; keeping active session',
        );
        return;
      }
      _enteredBackground = false;
      _debugLog.info('app_lifecycle', 'App resumed; validating BLE session');
      unawaited(_recoverBleAfterResume());
    }
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    unawaited(_updateOrientationLock());
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

  void _showConnectedSnackBar() {
    if (!mounted) return;
    final name = _appState.bleStatus;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(
                Icons.bluetooth_connected,
                color: Colors.white,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(name)),
            ],
          ),
          duration: const Duration(seconds: 3),
          behavior: SnackBarBehavior.floating,
        ),
      );
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
    return await _showPromptPage<String>(
      canPop: false,
      child: Builder(
        builder: (pageContext) {
          var pinValue = '';
          return _PromptCard(
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
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'PIN / Passkey',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (value) => pinValue = value,
                  onSubmitted: (value) {
                    final submit = value.trim();
                    Navigator.of(
                      pageContext,
                    ).pop(submit.isEmpty ? null : submit);
                  },
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(pageContext).pop(null),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  final value = pinValue.trim();
                  Navigator.of(pageContext).pop(value.isEmpty ? null : value);
                },
                child: const Text('Submit'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _maybeShowInitialPrivacyDialog() {
    if (!mounted) return;
    if (_appState.loading) return;
    if (_appState.settings.privacyAccepted) return;
    if (_index == 6) return;
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
          setState(() => _index = 6);
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
      setState(() => _index = 6);
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
    final result = await _showPromptPage<_PrivacyDialogAction>(
      canPop: !initialMode,
      child: Builder(
        builder: (pageContext) => _PromptCard(
          title: const Row(
            children: [
              Icon(Icons.privacy_tip_outlined, size: 18),
              SizedBox(width: 8),
              Expanded(child: Text('Privacy Policy')),
            ],
          ),
          content: Column(
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
                  pageContext,
                ).pop(_PrivacyDialogAction.readPolicy),
                child: const Text('Read full privacy policy'),
              ),
            ],
          ),
          actions: [
            if (initialMode)
              TextButton(
                onPressed: () => Navigator.of(
                  pageContext,
                ).pop(_PrivacyDialogAction.skipOrClose),
                child: const Text('Skip (Offline Only)'),
              )
            else
              TextButton(
                onPressed: () => Navigator.of(
                  pageContext,
                ).pop(_PrivacyDialogAction.skipOrClose),
                child: const Text('Cancel'),
              ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(pageContext).pop(_PrivacyDialogAction.accept),
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
            final desktopSidebarWidth = (constraints.maxWidth * 0.22)
                .clamp(224.0, 280.0)
                .toDouble();
            String scanHeaderLabel() {
              if (!_appState.bleConnected) return 'Idle';
              if (!_appState.bleScanning) return 'Paused';
              final liveStatus = _appState.bleStatus.trim();
              if (liveStatus.startsWith('Discovery Sent')) {
                return _formatScanProgressStatus(liveStatus);
              }
              if (liveStatus.startsWith('Discovery Complete')) {
                return liveStatus;
              }
              if (liveStatus.startsWith('Discovery Error')) {
                return liveStatus;
              }
              if (liveStatus.toLowerCase().contains('smart scan skipped')) {
                return liveStatus;
              }
              final isDiscoverDetailLine = liveStatus.contains(' · ');
              if (isDiscoverDetailLine &&
                  !liveStatus.startsWith('node_discover:') &&
                  !liveStatus.startsWith('Discovering')) {
                return liveStatus;
              }
              if (_appState.bleBusy) {
                switch (_appState.bleScanStatus) {
                  case 'advertising':
                    return _formatScanProgressStatus('Discovery Sent');
                  case 'waiting':
                    return _formatScanProgressStatus('Discovery Sent');
                  case 'querying':
                    return _formatScanProgressStatus('Discovery Sent');
                  case 'submitting':
                    return _formatScanProgressStatus('Discovery Sent');
                  case 'done':
                    return 'Discovery Complete';
                  case 'error':
                    return 'Discovery Error';
                  default:
                    return _formatScanProgressStatus('Discovery Sent');
                }
              }
              if (liveStatus.startsWith('node_discover:') ||
                  liveStatus.startsWith('Discovering')) {
                return _formatScanProgressStatus('Discovery Sent');
              }
              return _formatScanProgressStatus('Discovery Sent');
            }

            final headerStatusText = scanHeaderLabel();
            final headerCountdownText = _headerCountdownLabel();
            final hasCountdownBadge = headerCountdownText != null;
            final headerStatusLower = headerStatusText.toLowerCase();
            final headerStatusIsSmartSkip = headerStatusLower.contains(
              'smart scan skipped',
            );
            final shouldForceMarquee =
                headerStatusIsSmartSkip || headerStatusText.length >= 24;
            final headerStatusColor = headerStatusIsSmartSkip
                ? (Theme.of(context).brightness == Brightness.dark
                      ? const Color(0xFFFFEB3B)
                      : const Color(0xFFB45309))
                : Theme.of(context).textTheme.bodySmall?.color;
            Widget buildHeaderStatusPill() {
              final statusLineStyle = Theme.of(context).textTheme.bodySmall
                  ?.copyWith(
                    color: headerStatusColor,
                    fontWeight: headerStatusIsSmartSkip
                        ? FontWeight.w700
                        : FontWeight.w600,
                  );
              return Container(
                width: double.infinity,
                margin: EdgeInsets.only(right: hasCountdownBadge ? 6 : 0),
                padding: EdgeInsets.symmetric(
                  horizontal: compactHeader ? 8 : 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: OverflowMarqueeText(
                  text: headerStatusText,
                  pixelsPerSecond: 34,
                  gapPixels: 56,
                  alwaysScroll: shouldForceMarquee,
                  deferTextUpdatesUntilLoopEnd: true,
                  style: statusLineStyle,
                ),
              );
            }

            Widget? buildHeaderCountdownBadge() {
              if (headerCountdownText == null) return null;
              return Container(
                margin: const EdgeInsets.only(right: 6),
                padding: EdgeInsets.symmetric(
                  horizontal: compactHeader ? 8 : 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  headerCountdownText,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w700),
                ),
              );
            }

            final countdownBadge = buildHeaderCountdownBadge();

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
                          _navigateTo(i);
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
                        onShare: _shareApp,
                        onPrivacy: () {
                          _debugLog.info(
                            'ui_click',
                            'Sidebar privacy click (drawer)',
                          );
                          setState(() => _index = 6);
                          Navigator.of(context).pop();
                        },
                      ),
                    ),
              body: Row(
                children: [
                  if (desktop)
                    SizedBox(
                      width: desktopSidebarWidth,
                      child: _AppSidebar(
                        selectedIndex: _index,
                        onSelect: (i) {
                          _debugLog.info(
                            'ui_click',
                            'Sidebar select index=$i (desktop)',
                          );
                          _navigateTo(i);
                        },
                        onDiscord: () =>
                            _openUrl('https://discord.gg/Xyhjz7CtuW'),
                        onSupport: () => _openUrl(
                          'https://www.buymeacoffee.com/Just_Stuff_TM',
                        ),
                        onShare: _shareApp,
                        onPrivacy: () {
                          _debugLog.info(
                            'ui_click',
                            'Sidebar privacy click (desktop)',
                          );
                          setState(() => _index = 6);
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
                                  compactHeader
                                      ? Padding(
                                          padding: const EdgeInsets.only(
                                            right: 4,
                                          ),
                                          child: Icon(
                                            _appState.settings.forceOffline
                                                ? Icons.cloud_off
                                                : Icons.cloud,
                                            size: 18,
                                            color:
                                                _appState.settings.forceOffline
                                                ? Colors.orange
                                                : Colors.green,
                                          ),
                                        )
                                      : Padding(
                                          padding: const EdgeInsets.only(
                                            right: 8,
                                          ),
                                          child: Chip(
                                            avatar: Icon(
                                              _appState.settings.forceOffline
                                                  ? Icons.cloud_off
                                                  : Icons.cloud,
                                              size: 16,
                                              color:
                                                  _appState
                                                      .settings
                                                      .forceOffline
                                                  ? Colors.orange
                                                  : Colors.green,
                                            ),
                                            label: Text(
                                              _appState.settings.forceOffline
                                                  ? 'Offline'
                                                  : 'Online',
                                            ),
                                          ),
                                        ),
                                  Expanded(child: buildHeaderStatusPill()),
                                  ?countdownBadge,
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
    final observer = _latestObserverPosition();
    switch (index) {
      case 0:
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
            });
            _navigateTo(3);
          },
          focusHexId: _mapFocusHexId,
          focusNodeId: _mapFocusNodeId,
          resolvedNodeNames: resolvedNodeNames,
          scans: _appState.scanResults,
          rawScans: _appState.rawScans,
          nodesCount: _appState.nodes.length,
          statsRadiusMiles: _appState.settings.statsRadiusMiles,
          unitSystem: _appState.settings.unitSystem,
          tileCachingEnabled: _appState.settings.tileCachingEnabled,
          observerLat: observer?.$1,
          observerLng: observer?.$2,
          connectedRadioName: _appState.connectedRadioDisplayName,
          connectedRadioMeshId: _appState.connectedRadioMeshId8,
          bleUiEnabled: true,
          onClearFocusNodeId: () {
            if (_mapFocusNodeId == null) return;
            setState(() {
              _mapFocusNodeId = null;
            });
          },
          onTapNodes: () {
            _debugLog.info('ui_click', 'Stats bar -> Nodes tab');
            _navigateTo(2);
          },
          onTapScans: () {
            _debugLog.info('ui_click', 'Stats bar -> History tab');
            setState(() {
              _historyHexFilter = null;
            });
            _navigateTo(3);
          },
        );
      case 1:
        return ConnectionsPage(
          status: _appState.bleStatus,
          connected: _appState.bleConnected,
          busy: _appState.bleBusy || _appState.bleConnecting,
          bleUiEnabled: true,
          results: _appState.bleScanDevices,
          autoConnectEnabled: _appState.settings.bleAutoConnect,
          selectedDeviceId: _appState.bleSelectedDeviceId,
          onSelectBleDevice: _appState.selectBleDevice,
          onScanDevices: _appState.scanBleDevices,
          onToggleAutoConnect: (v) => _appState.updateSettings(
            _appState.settings.copyWith(bleAutoConnect: v),
          ),
          onConnect: _appState.connectBle,
          onDisconnect: _appState.disconnectBle,
        );
      case 2:
        return NodesPage(
          nodes: _appState.nodes,
          scanResults: _appState.scanResults,
          statsRadiusMiles: _appState.settings.statsRadiusMiles,
          observerLat: observer?.$1,
          observerLng: observer?.$2,
          onOpenMapForNode: (nodeId) {
            _debugLog.info('ui_click', 'Nodes -> Map for node=$nodeId');
            setState(() {
              _mapFocusNodeId = nodeId;
              _mapFocusHexId = null;
              _index = 0;
            });
          },
        );
      case 3:
        return HistoryPage(
          scans: _appState.scanResults,
          initialHexId: _historyHexFilter,
          unitSystem: _appState.settings.unitSystem,
          resolvedNodeNames: resolvedNodeNames,
          connectedRadioName: _appState.connectedRadioDisplayName,
          connectedRadioMeshId: _appState.connectedRadioMeshId8,
          statsRadiusMiles: _appState.settings.statsRadiusMiles,
          observerLat: observer?.$1,
          observerLng: observer?.$2,
          onOpenMapFromHex: (hexId) {
            _debugLog.info('ui_click', 'History -> Map for hex=$hexId');
            setState(() {
              _mapFocusHexId = hexId;
              _mapFocusNodeId = null;
              _index = 0;
            });
          },
        );
      case 4:
        return const ManualPage();
      case 5:
        return SettingsPage(
          settings: _appState.settings,
          syncing: _appState.syncing,
          localScanCount: _appState.localScanCount,
          uploadQueueCount: _appState.uploadQueueCount,
          lastSyncAt: _appState.lastSyncAt,
          lastSyncScanCount: _appState.lastSyncScanCount,
          periodicSyncEnabled: _appState.periodicSyncEnabled,
          periodicSyncWaitingForInternetTimeAnchor:
              _appState.periodicSyncWaitingForInternetTimeAnchor,
          nextPeriodicSyncDueAtUtc: _appState.nextPeriodicSyncDueAtUtc,
          bleConnected: _appState.bleConnected,
          bleBusy: _appState.bleBusy || _appState.bleConnecting,
          debugLogs: _appState.debugLogs,
          onClearDebugLogs: _appState.clearDebugLogs,
          onClearScanCache: _appState.clearScanCache,
          onDownloadOfflineTiles: _appState.downloadOfflineMapTiles,
          onClearOfflineTiles: _appState.clearOfflineMapTiles,
          onDeleteRadioData: _appState.deleteConnectedRadioData,
          deleteInProgress: _appState.deleteInProgress,
          connectedRadioId: _appState.connectedRadioMeshId8,
          darkMode: widget.darkMode,
          onToggleTheme: widget.onToggleTheme,
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
        );
      case 6:
        return const PrivacyPage();
      case 7:
        return ContactsPage(contacts: _appState.currentRadioContacts);
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

class _PromptPageShell extends StatelessWidget {
  const _PromptPageShell({required this.child, required this.canPop});

  final Widget child;
  final bool canPop;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: canPop,
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 620),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PromptCard extends StatelessWidget {
  const _PromptCard({
    required this.title,
    required this.content,
    required this.actions,
  });

  final Widget title;
  final Widget content;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DefaultTextStyle.merge(
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              child: title,
            ),
            const SizedBox(height: 12),
            content,
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.end,
              children: actions,
            ),
          ],
        ),
      ),
    );
  }
}

class _AppSidebar extends StatelessWidget {
  const _AppSidebar({
    required this.selectedIndex,
    required this.onSelect,
    required this.onDiscord,
    required this.onSupport,
    required this.onShare,
    required this.onPrivacy,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final Future<void> Function() onDiscord;
  final Future<void> Function() onSupport;
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
      child: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 18, 14, 10),
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
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  _NavButton(
                    label: i18n.t('nav.coverageMap'),
                    icon: Icons.map_outlined,
                    selected: selectedIndex == 0,
                    onTap: () => onSelect(0),
                  ),
                  _NavButton(
                    label: i18n.t('settings.connections'),
                    icon: Icons.bluetooth_searching,
                    selected: selectedIndex == 1,
                    onTap: () => onSelect(1),
                  ),
                  _NavButton(
                    label: i18n.t('settings.title'),
                    icon: Icons.settings_outlined,
                    selected: selectedIndex == 5,
                    onTap: () => onSelect(5),
                  ),
                  _NavButton(
                    label: i18n.t('nav.nodes'),
                    icon: Icons.settings_input_antenna,
                    selected: selectedIndex == 2,
                    onTap: () => onSelect(2),
                  ),
                  _NavButton(
                    label: i18n.t('nav.scanHistory'),
                    icon: Icons.radar_outlined,
                    selected: selectedIndex == 3,
                    onTap: () => onSelect(3),
                  ),
                  _NavButton(
                    label: i18n.t('nav.howToUse'),
                    icon: Icons.help_outline,
                    selected: selectedIndex == 4,
                    onTap: () => onSelect(4),
                  ),
                  _NavButton(
                    label: 'Contacts',
                    icon: Icons.contacts_outlined,
                    selected: selectedIndex == 7,
                    onTap: () => onSelect(7),
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
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
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
                Expanded(child: Text(label, softWrap: true)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
