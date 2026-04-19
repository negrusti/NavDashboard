// Copyright Jody M Sankey 2022
// This software may be modified and distributed under the terms
// of the MIT license. See the LICENCE.md file for details.

import 'dart:async';

import 'package:ambient_light/ambient_light.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'state/data_set.dart';
import 'state/history.dart';
import 'state/log_set.dart';
import 'state/settings.dart';
import 'state/specs.dart';
import 'ui/forms/view_help.dart';
import 'ui/theme.dart';
import 'ui/pages/data_table.dart';

/// A standard overlay used before and after loading.
const SystemUiOverlayStyle overlayStyle = SystemUiOverlayStyle(
  statusBarBrightness: Brightness.dark,
  statusBarIconBrightness: Brightness.light,
  statusBarColor: Colors.transparent,
  systemNavigationBarColor: Colors.black,
  systemNavigationBarIconBrightness: Brightness.light,
);

const double _ambientNightThresholdLux = 20.0;
const double _ambientDayThresholdLux = 80.0;
const double _ambientAverageAlpha = 0.15;
const Duration _ambientSwitchDelay = Duration(seconds: 30);

final _log = Logger('Main');

void main() {
  // TODO: move Wakelock and Full Screen Mode into options
  WidgetsFlutterBinding.ensureInitialized();
  WakelockPlus.toggle(enable: true);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  _requestStartupPermissions();
  
  final logSet = LogSet();
  Logger.root.onRecord.listen((record) => logSet.add(record));
  runApp(NmeaDashboardApp(logSet));
}

Future<void> _requestStartupPermissions() async {
  final locationStatus = await Permission.locationWhenInUse.status;
  if (locationStatus.isDenied) {
    await Permission.locationWhenInUse.request();
  }
}

/// The root widget for the application.
class NmeaDashboardApp extends StatelessWidget {
  final LogSet _logSet;

  const NmeaDashboardApp(this._logSet, {super.key});

  Future<_BootstrapData> _loadBootstrapData() async {
    return _BootstrapData(
        await Settings.create(), await HistoryManagerImpl.create());
  }

  // The root of the application needs to asynchronously load setttings
  // before deciding the theme and delegating the to a themed application.
  @override
  Widget build(BuildContext context) {
    /// Display the loading screen for at least the minimum time, potentially
    /// it could be diplayed longer if loading the setting takes a while.
    return FutureBuilder<_BootstrapData>(
        future: _loadBootstrapData(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done) {
            final settings = snapshot.data!.settings;
            final historyManager = snapshot.data!.historyManager;
            return MultiProvider(providers: [
              ChangeNotifierProvider<LogSet>(create: (_) => _logSet),
              ChangeNotifierProvider<Settings>(create: (_) => settings),
              ChangeNotifierProvider<NetworkSettings>(
                  create: (_) => settings.network),
              ChangeNotifierProvider<UiSettings>(create: (_) => settings.ui),
              ChangeNotifierProvider<PageSettings>(
                  create: (_) => settings.pages),
              ChangeNotifierProvider<DerivedDataSettings>(
                  create: (_) => settings.derived),
              ChangeNotifierProvider<DataSet>(
                  create: (_) => DataSet(
                      settings.network, settings.derived, historyManager)),
            ], child: _ThemedApp());
          } else {
            return _LoadingPage();
          }
        });
  }
}

class _BootstrapData {
  final Settings settings;
  final HistoryManager historyManager;

  _BootstrapData(this.settings, this.historyManager);
}

/// A simple stateless page to display while settings are loading.
class _LoadingPage extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
        value: overlayStyle,
        child: MaterialApp(
          title: 'NMEA Dashboard',
          theme: ThemeData.dark(),
          home: Scaffold(
            body: Center(
              child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text("NMEA Dashboard",
                        style: TextStyle(fontSize: 40)),
                    const SizedBox(height: 30),
                    Image.asset("assets/rounded_icon.png"),
                    const SizedBox(height: 60),
                    const SizedBox(
                        width: 250, child: LinearProgressIndicator()),
                  ]),
            ),
          ),
        ));
  }
}

/// The main functional application. Assumes settings can be provided.
class _ThemedApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final uiSettings = Provider.of<UiSettings>(context);
    return AnnotatedRegion<SystemUiOverlayStyle>(
        value: overlayStyle,
        child: MaterialApp(
          title: 'NMEA Dashboard',
          theme: createThemeData(uiSettings),
          home: _AmbientNightModeController(child: _HomePage()),
        ));
  }
}

class _AmbientNightModeController extends StatefulWidget {
  final Widget child;

  const _AmbientNightModeController({required this.child});

  @override
  State<_AmbientNightModeController> createState() =>
      _AmbientNightModeControllerState();
}

class _AmbientNightModeControllerState
    extends State<_AmbientNightModeController> {
  final AmbientLight _ambientLight = AmbientLight();
  StreamSubscription<double>? _subscription;
  bool? _subscribedAutoNightMode;
  double? _averageLux;
  bool? _pendingNightMode;
  DateTime? _pendingSince;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final autoNightMode = Provider.of<UiSettings>(context).autoNightMode;
    if (_subscribedAutoNightMode == autoNightMode) {
      return;
    }
    _subscribedAutoNightMode = autoNightMode;
    _subscription?.cancel();
    _subscription = null;
    _averageLux = null;
    _pendingNightMode = null;
    _pendingSince = null;

    if (autoNightMode) {
      _subscription = _ambientLight.ambientLightStream.listen(
        _handleAmbientLux,
        onError: (e) => _log.warning('Error reading ambient light: $e'),
      );
      _ambientLight.currentAmbientLight().then((lux) {
        if (lux != null) {
          _handleAmbientLux(lux);
        }
      }).catchError((e) {
        _log.warning('Error reading current ambient light: $e');
      });
    }
  }

  void _handleAmbientLux(double lux) {
    _averageLux = (_averageLux == null)
        ? lux
        : (_averageLux! * (1.0 - _ambientAverageAlpha)) +
            (lux * _ambientAverageAlpha);

    final uiSettings = Provider.of<UiSettings>(context, listen: false);
    final targetNightMode = _targetNightMode(_averageLux!);
    if (targetNightMode == null || targetNightMode == uiSettings.nightMode) {
      _pendingNightMode = null;
      _pendingSince = null;
      return;
    }

    final now = DateTime.now();
    if (_pendingNightMode != targetNightMode) {
      _pendingNightMode = targetNightMode;
      _pendingSince = now;
      return;
    }

    if (now.difference(_pendingSince!) >= _ambientSwitchDelay) {
      _log.info(
          'Auto night mode set to $targetNightMode at ${_averageLux!.toStringAsFixed(1)} lux');
      uiSettings.setNightMode(targetNightMode);
      _pendingNightMode = null;
      _pendingSince = null;
    }
  }

  bool? _targetNightMode(double averageLux) {
    if (averageLux <= _ambientNightThresholdLux) {
      return true;
    }
    if (averageLux >= _ambientDayThresholdLux) {
      return false;
    }
    return null;
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}

/// An intent to select one of the data pages.
class SelectPageIntent extends Intent {
  final int page;
  const SelectPageIntent(this.page);
}

/// Selects a data page using the supplied `PageController`.
class SelectPageAction extends Action<SelectPageIntent> {
  final PageController controller;

  SelectPageAction(this.controller);

  @override
  Object? invoke(SelectPageIntent intent) {
    controller.animateToPage(intent.page,
        duration: const Duration(milliseconds: 400), curve: Curves.ease);
    return null;
  }
}

class _HomePage extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final dataSettings = Provider.of<PageSettings>(context);
    final uiSettings = Provider.of<UiSettings>(context);
    final initialIdx = dataSettings.selectedPageIndex ?? 0;
    final controller = PageController(initialPage: initialIdx, keepPage: false);
    // Even though we tell the controller to not keep page it doesn't use the
    // initialIdx correctly. Force a transition post-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      controller.jumpToPage(initialIdx);
      if (uiSettings.firstRun) {
        uiSettings.clearFirstRun();
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => ViewHelpPage(
                title: 'Welcome to NMEA Dashboard',
                filename: 'help_overview.md'),
          ),
        );
      }
    });
    controller.addListener(() {
      // Record the page selection whenever we finish transitioning
      final currentPosition = controller.page;
      if (currentPosition == currentPosition!.roundToDouble()) {
        dataSettings.selectPage(currentPosition.round());
      }
    });

    return Shortcuts(
        shortcuts: const <ShortcutActivator, Intent>{
          CharacterActivator('1'): SelectPageIntent(0),
          CharacterActivator('2'): SelectPageIntent(1),
          CharacterActivator('3'): SelectPageIntent(2),
          CharacterActivator('4'): SelectPageIntent(3),
          CharacterActivator('5'): SelectPageIntent(4),
          CharacterActivator('6'): SelectPageIntent(5),
          CharacterActivator('7'): SelectPageIntent(6),
          CharacterActivator('8'): SelectPageIntent(7),
          CharacterActivator('9'): SelectPageIntent(8),
        },
        child: Actions(
            actions: {SelectPageIntent: SelectPageAction(controller)},
            child: Focus(
              autofocus: true,
              child: PageView(
                  controller: controller,
                  children: dataSettings.dataPageSpecs.map((pageSpec) {
                    return ChangeNotifierProvider<DataPageSpec>.value(
                        value: pageSpec, child: const DataTablePage());
                  }).toList()),
            )));
  }
}
