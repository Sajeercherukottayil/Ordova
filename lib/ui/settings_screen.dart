import 'package:flutter/material.dart';

import '../models.dart';
import '../server/kitchen_server.dart';
import '../services/prefs.dart';
import 'common.dart';
import 'connect_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _ips = localIpAddresses();

  Future<String?> _ask(String title, String initial, {TextInputType? keyboard, bool obscure = false}) {
    final c = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: c,
          autofocus: true,
          keyboardType: keyboard,
          obscureText: obscure,
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Save')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final client = ClientScope.of(context);
    final st = client.state.settings;
    final role = Prefs.instance.role;
    Future<void> save(ShopSettings next) => run(() => client.updateSettings(next));

    Widget header(String t) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 4),
      child: Text(
        t,
        style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.bold),
      ),
    );

    return Scaffold(
      drawer: const AppDrawer(current: 'settings'),
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const ConnectionBanner(),
          if (role != DeviceRole.kitchen) ...[
            header('Shop (shared by all devices)'),
            ListTile(
              leading: const Icon(Icons.storefront),
              title: const Text('Shop name'),
              subtitle: Text(st.shopName),
              onTap: () async {
                final v = await _ask('Shop name', st.shopName);
                if (v != null && v.isNotEmpty) save(st.copyWith(shopName: v));
              },
            ),
            ListTile(
              leading: const Icon(Icons.table_restaurant),
              title: const Text('Number of tables'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline),
                    onPressed: st.tableCount <= 1 ? null : () => save(st.copyWith(tableCount: st.tableCount - 1)),
                  ),
                  Text('${st.tableCount}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline),
                    onPressed: st.tableCount >= 60 ? null : () => save(st.copyWith(tableCount: st.tableCount + 1)),
                  ),
                ],
              ),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.takeout_dining),
              title: const Text('Parcel / take-away'),
              subtitle: const Text('Adds a "Parcel" tile next to the tables'),
              value: st.parcelEnabled,
              onChanged: (v) => save(st.copyWith(parcelEnabled: v)),
            ),
            ListTile(
              leading: const Icon(Icons.category),
              title: const Text('Menu categories'),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final c in st.categories)
                      InputChip(
                        label: Text(c),
                        onDeleted: () => save(st.copyWith(categories: st.categories.where((x) => x != c).toList())),
                      ),
                    ActionChip(
                      avatar: const Icon(Icons.add, size: 18),
                      label: const Text('Add'),
                      onPressed: () async {
                        final v = await _ask('New category', '');
                        if (v != null && v.isNotEmpty && !st.categories.contains(v)) {
                          save(st.copyWith(categories: [...st.categories, v]));
                        }
                      },
                    ),
                  ],
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.pin),
              title: const Text('Owner PIN'),
              subtitle: const Text('Protects sales report, menu and settings'),
              onTap: () async {
                final v = await _ask('New PIN (4–8 digits)', '', keyboard: TextInputType.number, obscure: true);
                if (v == null) return;
                if (!RegExp(r'^\d{4,8}$').hasMatch(v)) {
                  showMessage('PIN must be 4–8 digits', error: true);
                  return;
                }
                await run(() => client.updateSettings(st.copyWith(adminPin: v)), success: 'PIN changed');
              },
            ),
            ListTile(
              leading: const Icon(Icons.restart_alt),
              title: const Text('Restart order numbers from #1'),
              subtitle: Text('Next order is #${client.state.nextOrderNumber}'),
              onTap: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Restart order numbers?'),
                    content: const Text('Useful at the start of each day. Existing orders are kept.'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                      FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Restart')),
                    ],
                  ),
                );
                if (ok == true) run(client.resetOrderNumbers, success: 'Next order will be #1');
              },
            ),
          ],
          header('This device'),
          ListTile(
            leading: const Icon(Icons.badge),
            title: const Text('Staff name'),
            subtitle: Text(
              Prefs.instance.staffName.isEmpty ? 'Not set — shown on kitchen tickets' : Prefs.instance.staffName,
            ),
            onTap: () async {
              final v = await _ask('Staff name on this device', Prefs.instance.staffName);
              if (v != null) {
                await Prefs.instance.setStaffName(v);
                setState(() {});
              }
            },
          ),
          if (role == DeviceRole.kitchen)
            FutureBuilder(
              future: _ips,
              builder: (_, snap) => ListTile(
                leading: const Icon(Icons.wifi),
                title: const Text('Kitchen IP address'),
                subtitle: Text(
                  snap.data?.isNotEmpty == true
                      ? '${snap.data!.join(', ')}\nWaiter phones find this automatically, or type it in.'
                      : 'No Wi-Fi connection found',
                ),
                isThreeLine: true,
              ),
            )
          else
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('Kitchen device'),
              subtitle: Text(client.host ?? '-'),
              trailing: const Text('Change'),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ConnectScreen(
                    showBack: true,
                    onConnected: (host) async {
                      await Prefs.instance.setServerHost(host);
                      client.connect(host);
                      if (context.mounted) Navigator.pop(context);
                    },
                  ),
                ),
              ),
            ),
          ListTile(
            leading: const Icon(Icons.swap_horiz),
            title: const Text('Change device role'),
            subtitle: Text('Currently: ${role == DeviceRole.kitchen ? 'Kitchen' : 'Waiter'}'),
            onTap: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Change device role?'),
                  content: Text(
                    role == DeviceRole.kitchen
                        ? 'This device holds all orders and data. Waiters will be disconnected until a kitchen device is running again. Data stays saved on this device.'
                        : 'You will choose Kitchen or Waiter again.',
                  ),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                    FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Change')),
                  ],
                ),
              );
              if (ok != true) return;
              await Prefs.instance.setRole(null);
              await KitchenServer.instance.stop();
              if (!context.mounted) return;
              Navigator.popUntil(context, (r) => r.isFirst);
              appRestart.value++;
            },
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}
