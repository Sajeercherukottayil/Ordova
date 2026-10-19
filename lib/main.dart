import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'client/ordova_client.dart';
import 'server/kitchen_server.dart';
import 'services/alerts.dart';
import 'services/prefs.dart';
import 'ui/common.dart';
import 'ui/connect_screen.dart';
import 'ui/kitchen_screen.dart';
import 'ui/role_screen.dart';
import 'ui/tables_screen.dart';

final client = OrdovaClient();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Prefs.init();
  } catch (e, st) {
    // Show the problem instead of a black screen.
    runApp(
      MaterialApp(
        home: Scaffold(
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: SelectableText('Ordova could not start:\n\n$e\n\n$st'),
            ),
          ),
        ),
      ),
    );
    return;
  }
  runApp(const OrdovaApp());
}

class OrdovaApp extends StatelessWidget {
  const OrdovaApp({super.key});

  @override
  Widget build(BuildContext context) {
    const coffee = Color(0xFF6F4E37);
    return ClientScope(
      client: client,
      child: MaterialApp(
        title: 'Ordova',
        debugShowCheckedModeBanner: false,
        scaffoldMessengerKey: scaffoldMessengerKey,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: coffee, primary: coffee),
          appBarTheme: const AppBarTheme(backgroundColor: coffee, foregroundColor: Colors.white),
          cardTheme: const CardThemeData(margin: EdgeInsets.zero),
        ),
        home: ValueListenableBuilder(
          valueListenable: appRestart,
          builder: (_, n, _) => RootGate(key: ValueKey(n)),
        ),
      ),
    );
  }
}

/// Picks the first screen based on what this device is: kitchen or waiter.
class RootGate extends StatefulWidget {
  const RootGate({super.key});

  @override
  State<RootGate> createState() => _RootGateState();
}

class _RootGateState extends State<RootGate> {
  DeviceRole? _role = Prefs.instance.role;
  String? _host = Prefs.instance.serverHost;
  String? _serverError;
  StreamSubscription<ShopEvent>? _events;

  @override
  void initState() {
    super.initState();
    _setup();
  }

  Future<void> _setup() async {
    _events?.cancel();
    _events = null;
    switch (_role) {
      case DeviceRole.kitchen:
        try {
          await KitchenServer.instance.start();
        } catch (e) {
          setState(() => _serverError = '$e');
          return;
        }
        WakelockPlus.enable().ignore();
        client.connect('127.0.0.1');
        _events = client.events.listen((e) {
          final message = switch (e.kind) {
            'new_order' => 'New order #${e.number} — ${e.table}',
            'edited' => 'Order #${e.number} (${e.table}) was CHANGED — check the ticket',
            'cancelled' => 'Order #${e.number} (${e.table}) was CANCELLED',
            _ => null,
          };
          if (message == null) return;
          Alerts.newOrder();
          showMessage(message, error: e.kind == 'cancelled');
        });
      case DeviceRole.waiter:
        await KitchenServer.instance.stop();
        WakelockPlus.disable().ignore();
        if (_host != null) client.connect(_host!);
        _events = client.events.listen((e) {
          if (e.kind != 'ready') return;
          Alerts.ready();
          showMessage('Order #${e.number} for ${e.table} is READY — pick up from kitchen');
        });
      case null:
        break;
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _events?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final role = _role;
    if (role == null) {
      return RoleScreen(
        onSelected: (r) async {
          await Prefs.instance.setRole(r);
          setState(() => _role = r);
          _setup();
        },
      );
    }
    if (role == DeviceRole.kitchen) {
      if (_serverError != null) {
        return Scaffold(
          appBar: AppBar(title: const Text('Ordova')),
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('Could not start the kitchen server:\n$_serverError', textAlign: TextAlign.center),
            ),
          ),
        );
      }
      return const KitchenScreen();
    }
    if (_host == null) {
      return ConnectScreen(
        onConnected: (host) async {
          await Prefs.instance.setServerHost(host);
          setState(() => _host = host);
          client.connect(host);
        },
        onChangeRole: () async {
          await Prefs.instance.setRole(null);
          setState(() => _role = null);
          _setup();
        },
      );
    }
    return const TablesScreen();
  }
}
