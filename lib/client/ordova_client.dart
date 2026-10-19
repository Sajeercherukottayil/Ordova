import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models.dart';
import '../server/kitchen_server.dart';

class ShopEvent {
  final String kind; // new_order | ready | edited | cancelled
  final String orderId;
  final String table;
  final int number;
  const ShopEvent(this.kind, this.orderId, this.table, this.number);
}

class DiscoveredServer {
  final String host;
  final int port;
  final String shopName;
  const DiscoveredServer(this.host, this.port, this.shopName);
}

/// Every screen talks to the kitchen through this, including the kitchen
/// device itself (which connects to its own server on localhost). Keeps a
/// live copy of the shop state and reconnects automatically if Wi-Fi drops.
class OrdovaClient extends ChangeNotifier {
  WebSocket? _ws;
  String? _host;
  bool _connected = false;
  bool _disposed = false;
  Timer? _retry;
  ShopState _state = ShopState.empty;
  bool _hasState = false;
  int _requestSeq = 0;
  final _pending = <String, Completer<void>>{};
  final _events = StreamController<ShopEvent>.broadcast();

  String? get host => _host;
  bool get connected => _connected;
  bool get hasState => _hasState;
  ShopState get state => _state;
  Stream<ShopEvent> get events => _events.stream;

  void connect(String host) {
    if (_host == host && (_connected || _retry != null)) return;
    _host = host;
    _retry?.cancel();
    _retry = null;
    _ws?.close();
    _open();
  }

  Future<void> _open() async {
    final host = _host;
    if (host == null || _disposed) return;
    try {
      final ws = await WebSocket.connect('ws://$host:$serverPort/ws').timeout(const Duration(seconds: 5));
      if (_disposed || host != _host) {
        await ws.close();
        return;
      }
      ws.pingInterval = const Duration(seconds: 5);
      _ws = ws;
      _connected = true;
      notifyListeners();
      ws.listen(_onMessage, onDone: _onClosed, onError: (_) => _onClosed(), cancelOnError: true);
    } catch (_) {
      _scheduleRetry();
    }
  }

  void _onClosed() {
    _ws = null;
    if (_disposed) return;
    if (_connected) {
      _connected = false;
      notifyListeners();
    }
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(Exception('Lost connection to kitchen'));
    }
    _pending.clear();
    _scheduleRetry();
  }

  void _scheduleRetry() {
    if (_disposed) return;
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 2), () {
      _retry = null;
      _open();
    });
  }

  void _onMessage(dynamic data) {
    if (_disposed) return;
    final msg = jsonDecode(data as String) as Map<String, dynamic>;
    switch (msg['type']) {
      case 'state':
        _state = ShopState.fromJson(msg['state'] as Map<String, dynamic>);
        _hasState = true;
        notifyListeners();
      case 'event':
        _events.add(
          ShopEvent(msg['kind'] as String, msg['orderId'] as String, msg['table'] as String, msg['number'] as int),
        );
      case 'ack':
        final c = _pending.remove(msg['requestId']);
        final error = msg['error'] as String?;
        if (c == null || c.isCompleted) return;
        error == null ? c.complete() : c.completeError(Exception(error));
    }
  }

  Future<void> _send(String cmd, [Map<String, dynamic> data = const {}]) {
    final ws = _ws;
    if (ws == null || !_connected) {
      return Future.error(Exception('Not connected to kitchen'));
    }
    final id = '${_requestSeq++}';
    final completer = Completer<void>();
    _pending[id] = completer;
    ws.add(jsonEncode({'cmd': cmd, 'requestId': id, ...data}));
    return completer.future.timeout(
      const Duration(seconds: 6),
      onTimeout: () {
        _pending.remove(id);
        throw Exception('Kitchen did not respond');
      },
    );
  }

  // ------------------------------------------------------------- commands

  Future<void> placeOrder({
    required String table,
    required List<OrderItem> items,
    String note = '',
    String placedBy = '',
  }) => _send('place_order', {
    'table': table,
    'items': items.map((i) => i.toJson()).toList(),
    'note': note,
    'placedBy': placedBy,
  });

  Future<void> setStatus(String orderId, OrderStatus status) =>
      _send('set_status', {'orderId': orderId, 'status': status.name});

  Future<void> editOrder(String orderId, {required List<OrderItem> items, required String note}) =>
      _send('edit_order', {'orderId': orderId, 'items': items.map((i) => i.toJson()).toList(), 'note': note});

  Future<void> cancelOrder(String orderId) => setStatus(orderId, OrderStatus.cancelled);

  Future<void> toggleItem(String orderId, int index) => _send('toggle_item', {'orderId': orderId, 'index': index});

  Future<void> payTable(String table, String method) => _send('pay_table', {'table': table, 'method': method});

  Future<void> payOrders(List<String> orderIds, String method) =>
      _send('pay_orders', {'orderIds': orderIds, 'method': method});

  Future<void> moveTable(String from, String to) => _send('move_table', {'from': from, 'to': to});

  Future<void> saveMenuItem(MenuItem item) => _send('upsert_menu_item', {'item': item.toJson()});

  Future<void> deleteMenuItem(String id) => _send('delete_menu_item', {'id': id});

  Future<void> updateSettings(ShopSettings settings) => _send('update_settings', {'settings': settings.toJson()});

  Future<void> resetOrderNumbers() => _send('reset_order_numbers');

  // ------------------------------------------------------------ discovery

  /// Listens for kitchen beacons on the Wi-Fi. Cancel the subscription to stop.
  static Stream<DiscoveredServer> discover() {
    late StreamController<DiscoveredServer> controller;
    RawDatagramSocket? socket;
    final seen = <String>{};
    controller = StreamController<DiscoveredServer>(
      onListen: () async {
        try {
          socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, discoveryPort, reuseAddress: true);
          socket!.broadcastEnabled = true;
          socket!.listen((e) {
            if (e != RawSocketEvent.read) return;
            final dg = socket?.receive();
            if (dg == null) return;
            final parts = utf8.decode(dg.data, allowMalformed: true).split('|');
            if (parts.length < 3 || parts[0] != discoveryTag) return;
            final host = dg.address.address;
            if (seen.add(host)) {
              controller.add(DiscoveredServer(host, int.tryParse(parts[1]) ?? serverPort, parts.sublist(2).join('|')));
            }
          });
        } catch (e) {
          controller.addError(e);
        }
      },
      onCancel: () => socket?.close(),
    );
    return controller.stream;
  }

  @override
  void dispose() {
    _disposed = true;
    _retry?.cancel();
    _ws?.close();
    _events.close();
    super.dispose();
  }
}
