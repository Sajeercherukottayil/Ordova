import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ordova/client/ordova_client.dart';
import 'package:ordova/models.dart';
import 'package:ordova/server/kitchen_server.dart';

/// End-to-end: a real kitchen server and a real client over localhost.
void main() {
  late Directory dir;
  late OrdovaClient client;

  Future<void> until(bool Function() cond) async {
    for (var i = 0; i < 100 && !cond(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(cond(), isTrue);
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ordova_test');
    await KitchenServer.instance.start(dataDir: dir);
    client = OrdovaClient()..connect('127.0.0.1');
    await until(() => client.hasState);
  });

  tearDown(() async {
    client.dispose();
    await KitchenServer.instance.stop();
    await dir.delete(recursive: true);
  });

  test('order flows from waiter to kitchen to bill', () async {
    expect(client.state.menu, isNotEmpty, reason: 'seed menu loaded');
    final tea = client.state.menu.firstWhere((m) => m.name == 'Tea');
    final burger = client.state.menu.firstWhere((m) => m.name == 'Veg Burger');

    final events = <ShopEvent>[];
    final sub = client.events.listen(events.add);

    await client.placeOrder(table: 'T3', items: [
      OrderItem(menuId: tea.id, name: tea.name, price: tea.price, qty: 2, note: 'less sugar'),
      OrderItem(menuId: burger.id, name: burger.name, price: burger.price, qty: 1),
    ]);
    await until(() => client.state.orders.length == 1);
    final order = client.state.orders.single;
    expect(order.number, 1);
    expect(order.status, OrderStatus.newOrder);
    expect(order.total, 2 * 15 + 80);

    // Kitchen ticks both items -> ticket becomes ready and waiters are told.
    await client.toggleItem(order.id, 0);
    await until(() => client.state.orders.single.status == OrderStatus.preparing);
    await client.toggleItem(order.id, 1);
    await until(() => client.state.orders.single.status == OrderStatus.ready);
    await until(() => events.any((e) => e.kind == 'ready' && e.table == 'T3'));

    expect(client.state.billFor('T3'), hasLength(1));
    await client.payTable('T3', 'UPI');
    await until(() => client.state.billFor('T3').isEmpty);
    expect(client.state.orders.single.paymentMethod, 'UPI');

    await expectLater(client.payTable('T3', 'Cash'), throwsException);
    await sub.cancel();
  });

  test('one table can be split into separate bills', () async {
    final tea = client.state.menu.firstWhere((m) => m.name == 'Tea');
    OrderItem teas(int qty) => OrderItem(menuId: tea.id, name: tea.name, price: tea.price, qty: qty);

    await client.placeOrder(table: 'T1', items: [teas(1)]);
    await client.placeOrder(table: 'T1', items: [teas(3)]);
    await until(() => client.state.billFor('T1').length == 2);
    final first = client.state.billFor('T1').firstWhere((o) => o.number == 1);

    // Group 1 pays only their order; group 2's order stays open.
    await client.payOrders([first.id], 'Cash');
    await until(() => client.state.billFor('T1').length == 1);
    final remaining = client.state.billFor('T1').single;
    expect(remaining.number, 2);
    expect(remaining.total, 3 * tea.price);

    await client.payOrders([remaining.id], 'UPI');
    await until(() => client.state.billFor('T1').isEmpty);
    expect(client.state.orders.map((o) => o.paymentMethod), ['Cash', 'UPI']);
  });

  test('orders can be edited until ready and cancelled until paid', () async {
    final tea = client.state.menu.firstWhere((m) => m.name == 'Tea');
    final fries = client.state.menu.firstWhere((m) => m.name == 'French Fries');
    OrderItem line(MenuItem m, int qty) => OrderItem(menuId: m.id, name: m.name, price: m.price, qty: qty);

    final events = <ShopEvent>[];
    final sub = client.events.listen(events.add);

    await client.placeOrder(table: 'T2', items: [line(tea, 2), line(fries, 1)]);
    await until(() => client.state.orders.length == 1);
    var order = client.state.orders.single;

    // Kitchen ticks the tea, then the waiter drops the fries and adds a note.
    await client.toggleItem(order.id, 0);
    await client.editOrder(order.id, items: [line(tea, 2)], note: 'no ice');
    await until(() => client.state.orders.single.editedAt != null);
    order = client.state.orders.single;
    expect(order.items.single.done, isTrue, reason: 'unchanged item keeps its tick');
    expect(order.note, 'no ice');
    expect(order.total, 2 * tea.price);
    await until(() => events.any((e) => e.kind == 'edited'));

    // Ready orders can't be edited, but can still be cancelled before payment.
    await client.setStatus(order.id, OrderStatus.ready);
    await until(() => client.state.orders.single.status == OrderStatus.ready);
    await expectLater(client.editOrder(order.id, items: [line(tea, 3)], note: ''), throwsException);
    await client.cancelOrder(order.id);
    await until(() => client.state.orders.single.status == OrderStatus.cancelled);
    expect(client.state.billFor('T2'), isEmpty);
    await until(() => events.any((e) => e.kind == 'cancelled'));

    // Paid orders can't be cancelled.
    await client.placeOrder(table: 'T2', items: [line(tea, 1)]);
    await until(() => client.state.billFor('T2').length == 1);
    final paid = client.state.billFor('T2').single;
    await client.payOrders([paid.id], 'Cash');
    await until(() => client.state.billFor('T2').isEmpty);
    await expectLater(client.cancelOrder(paid.id), throwsException);
    await sub.cancel();
  });

  test('data survives a kitchen restart', () async {
    await client.updateSettings(client.state.settings.copyWith(shopName: 'Chai Point', tableCount: 5));
    await until(() => client.state.settings.shopName == 'Chai Point');
    client.dispose();
    await KitchenServer.instance.stop();
    await Future<void>.delayed(const Duration(milliseconds: 200));

    await KitchenServer.instance.start(dataDir: dir);
    client = OrdovaClient()..connect('127.0.0.1');
    await until(() => client.hasState);
    expect(client.state.settings.shopName, 'Chai Point');
    expect(client.state.settings.tables, ['T1', 'T2', 'T3', 'T4', 'T5', 'Parcel']);
  });
}
