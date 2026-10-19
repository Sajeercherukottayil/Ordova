import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';

import '../models.dart';

const serverPort = 4567;
const discoveryPort = 4568;
const discoveryTag = 'ORDOVA';

/// Runs on the kitchen device. Holds the single source of truth (menu, orders,
/// settings), saves it to disk, and pushes every change to all connected
/// devices over WebSocket. Also announces itself on the Wi-Fi via UDP
/// broadcast so waiter phones can find it without typing an IP.
class KitchenServer {
  KitchenServer._();
  static final instance = KitchenServer._();

  HttpServer? _http;
  RawDatagramSocket? _udp;
  Timer? _beacon;
  final _clients = <WebSocket>{};
  late File _file;
  late ShopState _state;
  Future<void> _saving = Future.value();
  final _rand = Random();

  bool get isRunning => _http != null;

  Future<void> start({Directory? dataDir}) async {
    if (isRunning) return;
    final dir = dataDir ?? await getApplicationDocumentsDirectory();
    _file = File('${dir.path}/ordova_data.json');
    _state = await _load();

    _http = await HttpServer.bind(InternetAddress.anyIPv4, serverPort, shared: true);
    _http!.listen(_handleRequest);
    await _startBeacon();
  }

  Future<void> stop() async {
    _beacon?.cancel();
    _udp?.close();
    for (final c in _clients.toList()) {
      await c.close();
    }
    _clients.clear();
    await _http?.close(force: true);
    _http = null;
    await _saving;
  }

  // ---------------------------------------------------------------- storage

  Future<ShopState> _load() async {
    ShopState state;
    try {
      state = ShopState.fromJson(jsonDecode(await _file.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      state = ShopState(settings: const ShopSettings(), menu: seedMenu(), orders: const [], nextOrderNumber: 1);
    }
    // Keep 90 days of history so the file stays small.
    final cutoff = DateTime.now().subtract(const Duration(days: 90));
    return ShopState(
      settings: state.settings,
      menu: state.menu,
      orders: state.orders.where((o) => o.createdAt.isAfter(cutoff) || o.isBillable).toList(),
      nextOrderNumber: state.nextOrderNumber,
    );
  }

  void _save() {
    final json = jsonEncode(_state.toJson());
    _saving = _saving
        .then((_) async {
          final tmp = File('${_file.path}.tmp');
          await tmp.writeAsString(json, flush: true);
          await tmp.rename(_file.path);
        })
        .catchError((_) {});
  }

  // ---------------------------------------------------------------- network

  Future<void> _handleRequest(HttpRequest req) async {
    if (req.uri.path == '/ws' && WebSocketTransformer.isUpgradeRequest(req)) {
      final ws = await WebSocketTransformer.upgrade(req);
      ws.pingInterval = const Duration(seconds: 5);
      _clients.add(ws);
      ws.add(_stateMessage());
      ws.listen(
        (data) => _handleMessage(ws, data),
        onDone: () => _clients.remove(ws),
        onError: (_) => _clients.remove(ws),
        cancelOnError: true,
      );
      return;
    }
    // Plain HTTP check so you can open http://<ip>:4567 in a browser to test.
    req.response
      ..headers.contentType = ContentType.json
      ..write(jsonEncode({'app': 'ordova', 'shop': _state.settings.shopName}));
    await req.response.close();
  }

  String _stateMessage() => jsonEncode({'type': 'state', 'state': _state.toJson()});

  void _broadcast(String message) {
    for (final c in _clients.toList()) {
      try {
        c.add(message);
      } catch (_) {
        _clients.remove(c);
      }
    }
  }

  void _commit(ShopState next, {Map<String, dynamic>? event}) {
    _state = next;
    _save();
    _broadcast(_stateMessage());
    if (event != null) _broadcast(jsonEncode({'type': 'event', ...event}));
  }

  void _reply(WebSocket ws, String requestId, {String? error}) {
    ws.add(jsonEncode({'type': 'ack', 'requestId': requestId, 'error': ?error}));
  }

  void _handleMessage(WebSocket ws, dynamic data) {
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(data as String) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final requestId = msg['requestId'] as String? ?? '';
    try {
      _apply(msg);
      _reply(ws, requestId);
    } catch (e) {
      _reply(ws, requestId, error: e.toString().replaceFirst('Exception: ', ''));
    }
  }

  // --------------------------------------------------------------- commands

  void _apply(Map<String, dynamic> msg) {
    final s = _state;
    switch (msg['cmd']) {
      case 'place_order':
        final items = (msg['items'] as List).map((e) => OrderItem.fromJson(e as Map<String, dynamic>)).toList();
        if (items.isEmpty) throw Exception('Order has no items');
        final order = Order(
          id: _newId(),
          number: s.nextOrderNumber,
          table: msg['table'] as String,
          items: items,
          note: msg['note'] as String? ?? '',
          placedBy: msg['placedBy'] as String? ?? '',
          status: OrderStatus.newOrder,
          createdAt: DateTime.now(),
        );
        _commit(
          _copy(orders: [...s.orders, order], nextOrderNumber: s.nextOrderNumber + 1),
          event: {'kind': 'new_order', 'orderId': order.id, 'table': order.table, 'number': order.number},
        );

      case 'set_status':
        final order = _order(msg['orderId']);
        final status = OrderStatus.values.byName(msg['status'] as String);
        if (status == OrderStatus.cancelled && !order.isCancellable) {
          throw Exception('Order #${order.number} is already paid or cancelled');
        }
        final updated = order.copyWith(status: status, readyAt: status == OrderStatus.ready ? DateTime.now() : null);
        final eventKind = switch (status) {
          OrderStatus.ready => 'ready',
          OrderStatus.cancelled => 'cancelled',
          _ => null,
        };
        _commit(
          _replaceOrder(updated),
          event: eventKind == null
              ? null
              : {'kind': eventKind, 'orderId': order.id, 'table': order.table, 'number': order.number},
        );

      case 'edit_order':
        final order = _order(msg['orderId']);
        if (!order.isEditable) {
          throw Exception('Order #${order.number} can no longer be edited (${order.status.label.toLowerCase()})');
        }
        final items = (msg['items'] as List).map((e) => OrderItem.fromJson(e as Map<String, dynamic>)).toList();
        if (items.isEmpty) throw Exception('An order needs at least one item. Cancel it instead.');
        // Keep the kitchen's ticks on items that didn't change or only got smaller.
        final kept = [
          for (final item in items)
            item.copyWith(
              done: order.items.any(
                (old) => old.done && old.menuId == item.menuId && old.note == item.note && item.qty <= old.qty,
              ),
            ),
        ];
        _commit(
          _replaceOrder(
            order.copyWith(items: kept, note: msg['note'] as String? ?? order.note, editedAt: DateTime.now()),
          ),
          event: {'kind': 'edited', 'orderId': order.id, 'table': order.table, 'number': order.number},
        );

      case 'toggle_item':
        final order = _order(msg['orderId']);
        final index = msg['index'] as int;
        final items = [...order.items];
        items[index] = items[index].copyWith(done: !items[index].done);
        var updated = order.copyWith(items: items);
        Map<String, dynamic>? event;
        // Every item ticked off -> the ticket is ready.
        if (items.every((i) => i.done) && order.status != OrderStatus.ready && order.status != OrderStatus.served) {
          updated = updated.copyWith(status: OrderStatus.ready, readyAt: DateTime.now());
          event = {'kind': 'ready', 'orderId': order.id, 'table': order.table, 'number': order.number};
        } else if (order.status == OrderStatus.newOrder) {
          updated = updated.copyWith(status: OrderStatus.preparing);
        }
        _commit(_replaceOrder(updated), event: event);

      case 'pay_table':
        final table = msg['table'] as String;
        final method = msg['method'] as String? ?? 'Cash';
        final now = DateTime.now();
        final bill = s.billFor(table);
        if (bill.isEmpty) throw Exception('Nothing to bill for $table');
        _commit(
          _copy(
            orders: [
              for (final o in s.orders)
                if (o.table == table && o.isBillable) o.copyWith(paidAt: now, paymentMethod: method) else o,
            ],
          ),
        );

      case 'pay_orders':
        // Separate bills: pay only some of a table's orders.
        final ids = (msg['orderIds'] as List).cast<String>().toSet();
        final method = msg['method'] as String? ?? 'Cash';
        final now = DateTime.now();
        if (!s.orders.any((o) => ids.contains(o.id) && o.isBillable)) throw Exception('Nothing to bill');
        _commit(
          _copy(
            orders: [
              for (final o in s.orders)
                if (ids.contains(o.id) && o.isBillable) o.copyWith(paidAt: now, paymentMethod: method) else o,
            ],
          ),
        );

      case 'move_table':
        final from = msg['from'] as String;
        final to = msg['to'] as String;
        _commit(
          _copy(
            orders: [
              for (final o in s.orders)
                if (o.table == from && o.isBillable) Order.fromJson({...o.toJson(), 'table': to}) else o,
            ],
          ),
        );

      case 'upsert_menu_item':
        final raw = msg['item'] as Map<String, dynamic>;
        final item = MenuItem.fromJson({
          ...raw,
          'id': (raw['id'] as String?)?.isNotEmpty == true ? raw['id'] : _newId(),
        });
        final exists = s.menu.any((m) => m.id == item.id);
        _commit(_copy(menu: exists ? [for (final m in s.menu) m.id == item.id ? item : m] : [...s.menu, item]));

      case 'delete_menu_item':
        _commit(_copy(menu: s.menu.where((m) => m.id != msg['id']).toList()));

      case 'update_settings':
        _commit(_copy(settings: ShopSettings.fromJson(msg['settings'] as Map<String, dynamic>)));

      case 'reset_order_numbers':
        _commit(_copy(nextOrderNumber: 1));

      default:
        throw Exception('Unknown command ${msg['cmd']}');
    }
  }

  Order _order(dynamic id) =>
      _state.orders.firstWhere((o) => o.id == id, orElse: () => throw Exception('Order not found'));

  ShopState _replaceOrder(Order updated) =>
      _copy(orders: [for (final o in _state.orders) o.id == updated.id ? updated : o]);

  ShopState _copy({ShopSettings? settings, List<MenuItem>? menu, List<Order>? orders, int? nextOrderNumber}) =>
      ShopState(
        settings: settings ?? _state.settings,
        menu: menu ?? _state.menu,
        orders: orders ?? _state.orders,
        nextOrderNumber: nextOrderNumber ?? _state.nextOrderNumber,
      );

  String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${_rand.nextInt(1 << 20).toRadixString(36)}';

  // -------------------------------------------------------------- discovery

  Future<void> _startBeacon() async {
    try {
      _udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _udp!.broadcastEnabled = true;
    } catch (_) {
      return; // discovery is a convenience; manual IP still works
    }
    Future<void> send() async {
      final payload = utf8.encode('$discoveryTag|$serverPort|${_state.settings.shopName}');
      final targets = {InternetAddress('255.255.255.255')};
      for (final ip in await localIpAddresses()) {
        final parts = ip.split('.');
        targets.add(InternetAddress('${parts[0]}.${parts[1]}.${parts[2]}.255'));
      }
      for (final t in targets) {
        try {
          _udp?.send(payload, t, discoveryPort);
        } catch (_) {}
      }
    }

    await send();
    _beacon = Timer.periodic(const Duration(seconds: 2), (_) => send());
  }
}

/// IPv4 addresses of this device on the local network (Wi-Fi / hotspot).
Future<List<String>> localIpAddresses() async {
  try {
    final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
    final ips = [
      for (final i in interfaces)
        for (final a in i.addresses) a.address,
    ];
    int rank(String ip) => ip.startsWith('192.168.')
        ? 0
        : ip.startsWith('10.')
        ? 1
        : ip.startsWith('172.')
        ? 2
        : 3;
    ips.sort((a, b) => rank(a).compareTo(rank(b)));
    return ips;
  } catch (_) {
    return [];
  }
}
