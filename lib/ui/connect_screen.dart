import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../client/ordova_client.dart';
import '../server/kitchen_server.dart';
import '../services/prefs.dart';

/// Finds the kitchen device on the Wi-Fi, or lets you type its IP.
class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key, required this.onConnected, this.showBack = false, this.onChangeRole});
  final ValueChanged<String> onConnected;
  final bool showBack;

  /// Goes back to the Kitchen / Waiter choice, in case the wrong one was picked.
  final VoidCallback? onChangeRole;

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _found = <DiscoveredServer>[];
  final _ip = TextEditingController(text: Prefs.instance.serverHost ?? '');
  StreamSubscription<DiscoveredServer>? _sub;
  bool _testing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _sub = OrdovaClient.discover().listen((s) => setState(() => _found.add(s)), onError: (_) {});
  }

  @override
  void dispose() {
    _sub?.cancel();
    _ip.dispose();
    super.dispose();
  }

  Future<void> _connect(String host) async {
    host = host.trim();
    if (host.isEmpty) return;
    setState(() {
      _testing = true;
      _error = null;
    });
    try {
      final ws = await WebSocket.connect('ws://$host:$serverPort/ws').timeout(const Duration(seconds: 4));
      await ws.close();
      widget.onConnected(host);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not reach kitchen at $host. Check the IP and Wi-Fi.');
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onChangeRole = widget.onChangeRole;
    return PopScope(
      canPop: onChangeRole == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) onChangeRole?.call();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Connect to kitchen'),
          automaticallyImplyLeading: widget.showBack,
          leading: onChangeRole == null
              ? null
              : IconButton(icon: const Icon(Icons.arrow_back), tooltip: 'Change device role', onPressed: onChangeRole),
        ),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Row(
              children: [
                const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 12),
                Text('Searching Wi-Fi for the kitchen…', style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 12),
            if (_found.isEmpty)
              const Text('Make sure the kitchen device has Ordova open and both devices are on the same Wi-Fi.'),
            for (final s in _found)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.soup_kitchen),
                  title: Text(s.shopName),
                  subtitle: Text(s.host),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _testing ? null : () => _connect(s.host),
                ),
              ),
            const SizedBox(height: 32),
            Text('Or enter the kitchen IP', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            const Text('The IP is shown at the top of the kitchen screen.'),
            const SizedBox(height: 12),
            TextField(
              controller: _ip,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                hintText: '192.168.1.20',
                errorText: _error,
                errorMaxLines: 3,
              ),
              onSubmitted: _connect,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _testing ? null : () => _connect(_ip.text),
              icon: _testing
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.link),
              label: const Text('Connect'),
            ),
            if (onChangeRole != null) ...[
              const SizedBox(height: 32),
              TextButton.icon(
                onPressed: onChangeRole,
                icon: const Icon(Icons.swap_horiz),
                label: const Text('Wrong choice? Change device role'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
