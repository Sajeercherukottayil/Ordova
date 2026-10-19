import 'package:flutter/material.dart';

import '../models.dart';
import '../server/kitchen_server.dart';
import '../services/prefs.dart';
import 'common.dart';

const _columns = [OrderStatus.newOrder, OrderStatus.preparing, OrderStatus.ready];

/// Live ticket board: New -> Preparing -> Ready -> Served.
class KitchenScreen extends StatelessWidget {
  const KitchenScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final client = ClientScope.of(context);
    final orders = client.state.orders.where((o) => o.status.isActive).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    List<Order> inColumn(OrderStatus s) => orders.where((o) => o.status == s).toList();

    return DefaultTabController(
      length: _columns.length,
      child: LayoutBuilder(
        builder: (context, box) {
          final wide = box.maxWidth >= 900;
          return Scaffold(
            drawer: const AppDrawer(current: 'kitchen'),
            appBar: AppBar(
              title: const Text('Kitchen'),
              actions: [if (Prefs.instance.role == DeviceRole.kitchen) const _IpChip()],
              bottom: wide
                  ? null
                  : TabBar(
                      labelColor: Colors.white,
                      unselectedLabelColor: Colors.white70,
                      indicatorColor: Colors.white,
                      tabs: [for (final s in _columns) Tab(text: '${s.label} (${inColumn(s).length})')],
                    ),
            ),
            body: Column(
              children: [
                const ConnectionBanner(),
                Expanded(
                  child: Ticker(
                    builder: (_) => wide
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (final s in _columns)
                                Expanded(
                                  child: _Column(status: s, orders: inColumn(s), showHeader: true),
                                ),
                            ],
                          )
                        : TabBarView(
                            children: [for (final s in _columns) _Column(status: s, orders: inColumn(s))],
                          ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _IpChip extends StatefulWidget {
  const _IpChip();

  @override
  State<_IpChip> createState() => _IpChipState();
}

class _IpChipState extends State<_IpChip> {
  final _ips = localIpAddresses();

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _ips,
    builder: (_, snap) {
      final ip = snap.data?.firstOrNull ?? '…';
      return Padding(
        padding: const EdgeInsets.only(right: 12),
        child: Tooltip(
          message: 'Waiters connect to this address',
          child: Chip(
            avatar: const Icon(Icons.wifi, size: 18),
            label: Text('IP $ip'),
            visualDensity: VisualDensity.compact,
          ),
        ),
      );
    },
  );
}

class _Column extends StatelessWidget {
  const _Column({required this.status, required this.orders, this.showHeader = false});
  final OrderStatus status;
  final List<Order> orders;
  final bool showHeader;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: statusColor(status).withValues(alpha: 0.06),
      child: Column(
        children: [
          if (showHeader)
            Container(
              width: double.infinity,
              color: statusColor(status),
              padding: const EdgeInsets.all(10),
              child: Text(
                '${status.label}  (${orders.length})',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ),
          Expanded(
            child: orders.isEmpty
                ? Center(
                    child: Text('No ${status.label.toLowerCase()} orders', style: const TextStyle(color: Colors.grey)),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(10),
                    itemCount: orders.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (_, i) => TicketCard(order: orders[i]),
                  ),
          ),
        ],
      ),
    );
  }
}

class TicketCard extends StatelessWidget {
  const TicketCard({super.key, required this.order});
  final Order order;

  @override
  Widget build(BuildContext context) {
    final client = ClientScope.read(context);
    final waitMinutes = DateTime.now().difference(order.createdAt).inMinutes;
    final late = order.status != OrderStatus.ready && waitMinutes >= 10;
    // The kitchen stops at Ready; the waiter marks Served after pickup.
    final isKitchen = Prefs.instance.role == DeviceRole.kitchen;
    final next = isKitchen && order.status == OrderStatus.ready ? null : order.status.next;

    return Card(
      elevation: 2,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: late ? BorderSide(color: Colors.red.shade600, width: 2) : BorderSide.none,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: statusColor(order.status),
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            child: Row(
              children: [
                Text(
                  order.table,
                  style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
                ),
                const SizedBox(width: 10),
                Text('#${order.number}', style: const TextStyle(color: Colors.white70, fontSize: 16)),
                if (order.editedAt != null) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(4)),
                    child: Text(
                      'EDITED',
                      style: TextStyle(color: statusColor(order.status), fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
                const Spacer(),
                Icon(late ? Icons.warning_amber : Icons.schedule, color: Colors.white, size: 18),
                const SizedBox(width: 4),
                Text(
                  elapsed(order.createdAt),
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                ),
                PopupMenuButton<String>(
                  iconColor: Colors.white,
                  onSelected: (v) async {
                    if (v == 'cancel') {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: Text('Cancel order #${order.number}?'),
                          content: Text('Table ${order.table}. It will be removed from the bill.'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
                            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Cancel order')),
                          ],
                        ),
                      );
                      if (ok == true) run(() => client.setStatus(order.id, OrderStatus.cancelled));
                    } else {
                      run(() => client.setStatus(order.id, OrderStatus.values.byName(v)));
                    }
                  },
                  itemBuilder: (_) => [
                    for (final s in _columns)
                      if (s != order.status) PopupMenuItem(value: s.name, child: Text('Move to ${s.label}')),
                    const PopupMenuItem(
                      value: 'cancel',
                      child: Text('Cancel order', style: TextStyle(color: Colors.red)),
                    ),
                  ],
                ),
              ],
            ),
          ),
          for (var i = 0; i < order.items.length; i++)
            InkWell(
              onTap: () => run(() => client.toggleItem(order.id, i)),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      order.items[i].done ? Icons.check_box : Icons.check_box_outline_blank,
                      color: order.items[i].done ? Colors.green : Colors.grey,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${order.items[i].qty} × ${order.items[i].name}',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              decoration: order.items[i].done ? TextDecoration.lineThrough : null,
                              color: order.items[i].done ? Colors.grey : null,
                            ),
                          ),
                          if (order.items[i].note.isNotEmpty)
                            Text(
                              '→ ${order.items[i].note}',
                              style: TextStyle(color: Colors.deepOrange.shade700, fontStyle: FontStyle.italic),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (order.note.isNotEmpty)
            Container(
              margin: const EdgeInsets.fromLTRB(12, 4, 12, 0),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: Colors.amber.shade100, borderRadius: BorderRadius.circular(6)),
              child: Text('Note: ${order.note}', style: const TextStyle(fontWeight: FontWeight.w500)),
            ),
          Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                if (order.placedBy.isNotEmpty)
                  Expanded(
                    child: Text('by ${order.placedBy}', style: const TextStyle(color: Colors.grey)),
                  ),
                if (order.placedBy.isEmpty) const Spacer(),
                if (next == null && order.status == OrderStatus.ready)
                  Text(
                    'Waiting for pickup',
                    style: TextStyle(color: Colors.green.shade700, fontWeight: FontWeight.w600),
                  ),
                if (next != null)
                  FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: statusColor(next)),
                    onPressed: () => run(() => client.setStatus(order.id, next)),
                    icon: Icon(switch (next) {
                      OrderStatus.preparing => Icons.local_fire_department,
                      OrderStatus.ready => Icons.notifications_active,
                      _ => Icons.done_all,
                    }),
                    label: Text(switch (next) {
                      OrderStatus.preparing => 'Start',
                      OrderStatus.ready => 'Ready',
                      _ => 'Served',
                    }),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
