import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models.dart';
import 'billing_screen.dart';
import 'common.dart';
import 'take_order_screen.dart';

/// Waiter home: every table at a glance.
class TablesScreen extends StatelessWidget {
  const TablesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final client = ClientScope.of(context);
    final s = client.state;
    return Scaffold(
      drawer: const AppDrawer(current: 'tables'),
      appBar: AppBar(title: Text(s.settings.shopName)),
      body: Column(
        children: [
          const ConnectionBanner(),
          if (!client.hasState)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.all(12),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 200,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 1.1,
                ),
                itemCount: s.settings.tables.length,
                itemBuilder: (_, i) => _TableTile(table: s.settings.tables[i]),
              ),
            ),
        ],
      ),
    );
  }
}

class _TableTile extends StatelessWidget {
  const _TableTile({required this.table});
  final String table;

  @override
  Widget build(BuildContext context) {
    final s = ClientScope.of(context).state;
    final bill = s.billFor(table);
    final active = bill.where((o) => o.status.isActive).toList();
    final readyCount = active.where((o) => o.status == OrderStatus.ready).length;
    final cooking = active.length - readyCount;
    final total = bill.fold<double>(0, (sum, o) => sum + o.total);

    final (Color color, String label) = readyCount > 0
        ? (Colors.green.shade600, '$readyCount ready!')
        : cooking > 0
        ? (Colors.orange.shade700, '$cooking in kitchen')
        : bill.isNotEmpty
        ? (Colors.blue.shade600, 'Served')
        : (Colors.grey.shade400, 'Free');

    return Material(
      color: color,
      borderRadius: BorderRadius.circular(16),
      elevation: bill.isEmpty ? 0 : 3,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            settings: bill.isEmpty ? null : const RouteSettings(name: TableScreen.routeName),
            builder: (_) => bill.isEmpty ? TakeOrderScreen(table: table) : TableScreen(table: table),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(table == 'Parcel' ? Icons.takeout_dining : Icons.table_restaurant, color: Colors.white, size: 30),
              Text(
                table,
                style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
              ),
              Text(
                label,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
              ),
              if (total > 0) Text(formatMoney(total), style: const TextStyle(color: Colors.white70)),
            ],
          ),
        ),
      ),
    );
  }
}

/// One table: its tickets and statuses, add more items, go to bill.
class TableScreen extends StatelessWidget {
  const TableScreen({super.key, required this.table});
  final String table;

  /// Lets the bill screen return here after a payment.
  static const routeName = 'table';

  @override
  Widget build(BuildContext context) {
    final client = ClientScope.of(context);
    final s = client.state;
    final bill = s.billFor(table)..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final total = bill.fold<double>(0, (sum, o) => sum + o.total);

    return Scaffold(
      appBar: AppBar(
        title: Text('Table $table'),
        actions: [
          if (bill.isNotEmpty)
            IconButton(
              tooltip: 'Move to another table',
              icon: const Icon(Icons.swap_horiz),
              onPressed: () => _moveTable(context),
            ),
        ],
      ),
      body: Column(
        children: [
          const ConnectionBanner(),
          Expanded(
            child: bill.isEmpty
                ? const Center(child: Text('No open orders on this table'))
                : Ticker(
                    builder: (_) => ListView.separated(
                      padding: const EdgeInsets.all(12),
                      itemCount: bill.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (_, i) => _OrderSummaryCard(order: bill[i]),
                    ),
                  ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              // With several orders, each one is billed from its own details page.
              if (bill.length == 1) ...[
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => openBill(context, table),
                    icon: const Icon(Icons.receipt_long),
                    label: Text('Bill ${formatMoney(total)}'),
                  ),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: FilledButton.icon(
                  onPressed: () =>
                      Navigator.push(context, MaterialPageRoute(builder: (_) => TakeOrderScreen(table: table))),
                  icon: const Icon(Icons.add),
                  label: const Text('New order'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _moveTable(BuildContext context) async {
    final client = ClientScope.read(context);
    final s = client.state;
    final to = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('Move $table to'),
        children: [
          for (final t in s.settings.tables)
            if (t != table && s.billFor(t).isEmpty)
              SimpleDialogOption(onPressed: () => Navigator.pop(ctx, t), child: Text(t)),
        ],
      ),
    );
    if (to == null) return;
    final ok = await run(() => client.moveTable(table, to), success: 'Moved $table to $to');
    if (ok && context.mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          settings: const RouteSettings(name: TableScreen.routeName),
          builder: (_) => TableScreen(table: to),
        ),
      );
    }
  }
}

class _OrderSummaryCard extends StatelessWidget {
  const _OrderSummaryCard({required this.order});
  final Order order;

  @override
  Widget build(BuildContext context) {
    final client = ClientScope.read(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => OrderDetailScreen(orderId: order.id))),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('#${order.number}', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(width: 8),
                  StatusChip(order.status),
                  const Spacer(),
                  Text(elapsed(order.createdAt), style: const TextStyle(color: Colors.grey)),
                  const Icon(Icons.chevron_right, color: Colors.grey),
                ],
              ),
              const SizedBox(height: 8),
              for (final item in order.items)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Expanded(child: Text('${item.qty} × ${item.name}${item.note.isEmpty ? '' : '  (${item.note})'}')),
                      Text(formatMoney(item.total)),
                    ],
                  ),
                ),
              if (order.note.isNotEmpty)
                Text('Note: ${order.note}', style: const TextStyle(fontStyle: FontStyle.italic)),
              if (order.status == OrderStatus.ready) ...[
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: Colors.green.shade600),
                    onPressed: () => run(() => client.setStatus(order.id, OrderStatus.served)),
                    icon: const Icon(Icons.done_all),
                    label: const Text('Picked up & served'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Opens the bill for a table, or for just one order when [orderId] is given.
Future<void> openBill(BuildContext context, String table, {String? orderId}) async {
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => BillScreen(table: table, onlyOrderId: orderId),
    ),
  );
}

/// Full details of one order, with its own Bill button.
class OrderDetailScreen extends StatelessWidget {
  const OrderDetailScreen({super.key, required this.orderId});
  final String orderId;

  @override
  Widget build(BuildContext context) {
    final client = ClientScope.of(context);
    final order = client.state.orders.where((o) => o.id == orderId).firstOrNull;
    final theme = Theme.of(context);

    if (order == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('Order not found')),
      );
    }

    Widget info(IconData icon, String text) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(icon, size: 18, color: Colors.grey),
          const SizedBox(width: 8),
          Expanded(child: Text(text)),
        ],
      ),
    );

    return Scaffold(
      appBar: AppBar(title: Text('Order #${order.number} · ${order.table}')),
      body: Column(
        children: [
          const ConnectionBanner(),
          Expanded(
            child: Ticker(
              builder: (_) => ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Row(
                    children: [
                      Text('Order #${order.number}', style: theme.textTheme.headlineSmall),
                      const SizedBox(width: 12),
                      StatusChip(order.status),
                      if (order.isPaid) ...[const SizedBox(width: 8), const Chip(label: Text('Paid'))],
                    ],
                  ),
                  const SizedBox(height: 8),
                  info(Icons.table_restaurant, 'Table ${order.table}'),
                  info(
                    Icons.schedule,
                    '${DateFormat('h:mm a').format(order.createdAt)} · ${elapsed(order.createdAt)} ago',
                  ),
                  if (order.placedBy.isNotEmpty) info(Icons.person, 'Taken by ${order.placedBy}'),
                  if (order.isPaid)
                    info(
                      Icons.payments,
                      'Paid ${DateFormat('h:mm a').format(order.paidAt!)} by ${order.paymentMethod ?? 'Cash'}',
                    ),
                  if (order.editedAt != null)
                    info(Icons.edit, 'Edited ${DateFormat('h:mm a').format(order.editedAt!)}'),
                  if (order.isCancellable) ...[
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: order.isEditable
                                ? () => Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => TakeOrderScreen(table: order.table, editing: order),
                                    ),
                                  )
                                : null,
                            icon: const Icon(Icons.edit),
                            label: const Text('Edit order'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(foregroundColor: Colors.red.shade700),
                            onPressed: () => _cancel(context, order),
                            icon: const Icon(Icons.cancel_outlined),
                            label: const Text('Cancel order'),
                          ),
                        ),
                      ],
                    ),
                    if (!order.isEditable)
                      const Padding(
                        padding: EdgeInsets.only(top: 6),
                        child: Text(
                          'Already ready in the kitchen — use "New order" on the table to add items.',
                          style: TextStyle(color: Colors.grey),
                        ),
                      ),
                  ],
                  const Divider(height: 32),
                  for (final item in order.items)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(item.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
                                if (item.note.isNotEmpty)
                                  Text(item.note, style: TextStyle(color: Colors.deepOrange.shade700)),
                              ],
                            ),
                          ),
                          SizedBox(width: 90, child: Text('${item.qty} × ${formatMoney(item.price)}')),
                          SizedBox(
                            width: 80,
                            child: Text(
                              formatMoney(item.total),
                              textAlign: TextAlign.right,
                              style: const TextStyle(fontSize: 16),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (order.note.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(top: 12),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(color: Colors.amber.shade100, borderRadius: BorderRadius.circular(8)),
                      child: Text('Note: ${order.note}'),
                    ),
                  const Divider(height: 32),
                  Row(
                    children: [
                      Text('Total', style: theme.textTheme.titleLarge),
                      const Spacer(),
                      Text(
                        formatMoney(order.total),
                        style: theme.textTheme.headlineSmall!.copyWith(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: !order.isBillable
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    if (order.status == OrderStatus.ready) ...[
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => run(() => client.setStatus(order.id, OrderStatus.served)),
                          icon: const Icon(Icons.done_all),
                          label: const Text('Served'),
                        ),
                      ),
                      const SizedBox(width: 12),
                    ],
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () => openBill(context, order.table, orderId: order.id),
                        icon: const Icon(Icons.receipt_long),
                        label: Text('Bill ${formatMoney(order.total)}'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Future<void> _cancel(BuildContext context, Order order) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Cancel order #${order.number}?'),
        content: Text(
          '${order.items.map((i) => '${i.qty} ${i.name}').join(', ')}\n\n'
          'It will be removed from the ${order.table} bill and the kitchen will be told.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep order')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Cancel order'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final client = ClientScope.read(context);
    if (!await run(() => client.cancelOrder(order.id), success: 'Order #${order.number} cancelled') ||
        !context.mounted) {
      return;
    }
    // Back to the table if it still has orders, otherwise to the tables grid.
    final tableStillBusy = client.state.billFor(order.table).any((o) => o.id != order.id);
    Navigator.popUntil(context, (r) => r.isFirst || (tableStillBusy && r.settings.name == TableScreen.routeName));
  }
}
