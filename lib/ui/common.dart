import 'dart:async';

import 'package:flutter/material.dart';

import '../client/ordova_client.dart';
import '../models.dart';
import '../services/prefs.dart';
import 'billing_screen.dart';
import 'kitchen_screen.dart';
import 'menu_screen.dart';
import 'sales_screen.dart';
import 'settings_screen.dart';
import 'tables_screen.dart';

final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

/// Bumped to tear down and rebuild the app (e.g. after changing device role).
final appRestart = ValueNotifier(0);

/// Makes the [OrdovaClient] available to every screen and rebuilds them when
/// the shop state changes.
class ClientScope extends InheritedNotifier<OrdovaClient> {
  const ClientScope({super.key, required OrdovaClient client, required super.child}) : super(notifier: client);

  static OrdovaClient of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<ClientScope>()!.notifier!;

  static OrdovaClient read(BuildContext context) => context.getInheritedWidgetOfExactType<ClientScope>()!.notifier!;
}

void showMessage(String text, {bool error = false}) {
  final messenger = scaffoldMessengerKey.currentState;
  messenger?.hideCurrentSnackBar();
  messenger?.showSnackBar(
    SnackBar(
      content: Text(text),
      backgroundColor: error ? Colors.red.shade700 : null,
      behavior: SnackBarBehavior.floating,
    ),
  );
}

/// Runs a client command and shows any error as a snackbar.
Future<bool> run(Future<void> Function() action, {String? success}) async {
  try {
    await action();
    if (success != null) showMessage(success);
    return true;
  } catch (e) {
    showMessage(e.toString().replaceFirst('Exception: ', ''), error: true);
    return false;
  }
}

Color statusColor(OrderStatus s) => switch (s) {
  OrderStatus.newOrder => Colors.red.shade600,
  OrderStatus.preparing => Colors.orange.shade700,
  OrderStatus.ready => Colors.green.shade600,
  OrderStatus.served => Colors.blueGrey,
  OrderStatus.cancelled => Colors.grey,
};

class StatusChip extends StatelessWidget {
  const StatusChip(this.status, {super.key});
  final OrderStatus status;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(color: statusColor(status), borderRadius: BorderRadius.circular(20)),
    child: Text(
      status.label,
      style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
    ),
  );
}

String elapsed(DateTime since) {
  final d = DateTime.now().difference(since);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min';
  return '${d.inHours}h ${d.inMinutes % 60}m';
}

/// Rebuilds its child every [period] so timers on tickets stay current.
class Ticker extends StatefulWidget {
  const Ticker({super.key, required this.builder, this.period = const Duration(seconds: 20)});
  final WidgetBuilder builder;
  final Duration period;

  @override
  State<Ticker> createState() => _TickerState();
}

class _TickerState extends State<Ticker> {
  late final Timer _timer = Timer.periodic(widget.period, (_) => setState(() {}));

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

/// Thin red bar shown while the device can't reach the kitchen.
class ConnectionBanner extends StatelessWidget {
  const ConnectionBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final client = ClientScope.of(context);
    if (client.connected) return const SizedBox.shrink();
    return Material(
      color: Colors.red.shade700,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
        child: Row(
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Not connected to kitchen (${client.host ?? '-'}). Reconnecting…',
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ admin PIN

bool _adminUnlocked = false;

/// Menu, sales and settings are behind the owner's PIN. Once entered
/// it stays unlocked until the app is closed.
Future<bool> requirePin(BuildContext context) async {
  if (_adminUnlocked) return true;
  final pin = ClientScope.read(context).state.settings.adminPin;
  final controller = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      String? error;
      return StatefulBuilder(
        builder: (ctx, setState) {
          void submit() {
            if (controller.text == pin) {
              Navigator.pop(ctx, true);
            } else {
              setState(() => error = 'Wrong PIN');
            }
          }

          return AlertDialog(
            title: const Text('Owner PIN'),
            content: TextField(
              controller: controller,
              autofocus: true,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 8,
              decoration: InputDecoration(errorText: error, helperText: 'Default PIN is 1234'),
              onSubmitted: (_) => submit(),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              FilledButton(onPressed: submit, child: const Text('Unlock')),
            ],
          );
        },
      );
    },
  );
  _adminUnlocked = ok == true;
  return _adminUnlocked;
}

// --------------------------------------------------------------------- drawer

class AppDrawer extends StatelessWidget {
  const AppDrawer({super.key, required this.current});
  final String current;

  @override
  Widget build(BuildContext context) {
    final client = ClientScope.of(context);
    final role = Prefs.instance.role;
    final s = client.state;
    final unpaidTables = s.settings.tables.where((t) => s.billFor(t).isNotEmpty).length;
    final homeKey = role == DeviceRole.kitchen ? 'kitchen' : 'tables';

    Widget item(String key, IconData icon, String label, Widget Function() page, {bool admin = false, String? badge}) {
      return ListTile(
        leading: Icon(icon),
        title: Text(label),
        selected: current == key,
        trailing: badge == null ? (admin ? const Icon(Icons.lock_outline, size: 16) : null) : Badge(label: Text(badge)),
        onTap: () async {
          final nav = Navigator.of(context);
          nav.pop();
          if (current == key) return;
          if (admin && !await requirePin(nav.context)) return;
          nav.popUntil((r) => r.isFirst);
          if (key == homeKey) return;
          nav.push(
            MaterialPageRoute(
              settings: RouteSettings(name: key),
              builder: (_) => page(),
            ),
          );
        },
      );
    }

    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          DrawerHeader(
            decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                const Icon(Icons.local_cafe, color: Colors.white, size: 40),
                const SizedBox(height: 8),
                Text(
                  s.settings.shopName,
                  style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
                ),
                Text(
                  role == DeviceRole.kitchen ? 'Kitchen device' : 'Waiter device',
                  style: const TextStyle(color: Colors.white70),
                ),
              ],
            ),
          ),
          // The kitchen device only receives orders and marks them ready;
          // ordering, billing, sales and menu are done on waiter phones.
          if (role == DeviceRole.kitchen)
            item('kitchen', Icons.soup_kitchen, 'Kitchen board', () => const KitchenScreen())
          else ...[
            item('tables', Icons.table_restaurant, 'Tables & orders', () => const TablesScreen()),
            item('kitchen', Icons.soup_kitchen, 'Kitchen board', () => const KitchenScreen()),
            const Divider(),
            item(
              'billing',
              Icons.receipt_long,
              'Billing',
              () => const BillingScreen(),
              badge: unpaidTables > 0 ? '$unpaidTables' : null,
            ),
            item('sales', Icons.bar_chart, 'Sales report', () => const SalesScreen(), admin: true),
            item('menu', Icons.restaurant_menu, 'Menu', () => const MenuScreen(), admin: true),
          ],
          const Divider(),
          item('settings', Icons.settings, 'Settings', () => const SettingsScreen(), admin: true),
        ],
      ),
    );
  }
}
