import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models.dart';
import 'common.dart';
import 'tables_screen.dart';

const paymentMethods = ['Cash', 'UPI', 'Card'];

/// Tables with an open bill, plus today's paid bills.
class BillingScreen extends StatelessWidget {
  const BillingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = ClientScope.of(context).state;
    final open = [
      for (final t in {...s.settings.tables, ...s.orders.where((o) => o.isBillable).map((o) => o.table)})
        if (s.billFor(t).isNotEmpty) t,
    ];
    final now = DateTime.now();
    final paidToday = <String, List<Order>>{};
    for (final o in s.orders.where((o) => o.paidAt != null && DateUtils.isSameDay(o.paidAt, now))) {
      paidToday.putIfAbsent('${o.table}|${o.paidAt!.toIso8601String()}', () => []).add(o);
    }
    final paidGroups = paidToday.values.toList()..sort((a, b) => b.first.paidAt!.compareTo(a.first.paidAt!));

    return Scaffold(
      drawer: const AppDrawer(current: 'billing'),
      appBar: AppBar(title: const Text('Billing')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          const ConnectionBanner(),
          Text('Open bills', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (open.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('No open bills')),
          for (final t in open) _openBillTile(context, s, t),
          const SizedBox(height: 24),
          Text('Paid today (${paidGroups.length})', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final g in paidGroups)
            ListTile(
              dense: true,
              leading: const Icon(Icons.check_circle, color: Colors.green),
              title: Text('${g.first.table}  ·  ${formatMoney(g.fold<double>(0, (sum, o) => sum + o.total))}'),
              subtitle: Text(
                '${DateFormat.jm().format(g.first.paidAt!)} · ${g.first.paymentMethod ?? ''} · orders ${g.map((o) => '#${o.number}').join(', ')}',
              ),
            ),
        ],
      ),
    );
  }

  Widget _openBillTile(BuildContext context, ShopState s, String table) {
    final bill = s.billFor(table);
    final total = bill.fold<double>(0, (sum, o) => sum + o.total);
    final pending = bill.where((o) => o.status.isActive).length;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(child: Text(table.length > 3 ? table.substring(0, 1) : table)),
        title: Text(table, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text('${bill.length} order(s)${pending > 0 ? ' · $pending still in kitchen' : ''}'),
        trailing: Text(formatMoney(total), style: Theme.of(context).textTheme.titleMedium),
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => BillScreen(table: table))),
      ),
    );
  }
}

/// Bill for one table. Every open order is listed with a checkbox, so one
/// table can be split into separate bills (e.g. two groups of customers).
class BillScreen extends StatefulWidget {
  const BillScreen({super.key, required this.table, this.onlyOrderId});
  final String table;

  /// When set, the bill covers just this order, with no checkboxes. Used from
  /// an order's details page.
  final String? onlyOrderId;

  @override
  State<BillScreen> createState() => _BillScreenState();
}

class _BillScreenState extends State<BillScreen> {
  // Orders left out of this bill. Tracking exclusions (not selections) means
  // an order added to the table while this screen is open is included.
  final _excluded = <String>{};

  @override
  Widget build(BuildContext context) {
    final client = ClientScope.of(context);
    final s = client.state;
    final table = widget.table;
    final only = widget.onlyOrderId;
    final open = s.billFor(table).where((o) => only == null || o.id == only).toList()
      ..sort((a, b) => a.number.compareTo(b.number));
    final selected = open.where((o) => !_excluded.contains(o.id)).toList();
    final split = open.length > 1;

    // Merge identical items across the selected orders: 2 tea + 1 tea = 3 tea.
    final lines = <String, OrderItem>{};
    for (final item in selected.expand((o) => o.items)) {
      final key = '${item.name}|${item.price}';
      final prev = lines[key];
      lines[key] = prev == null ? item : prev.copyWith(qty: prev.qty + item.qty);
    }
    final total = selected.fold<double>(0, (sum, o) => sum + o.total);
    final qtyTotal = lines.values.fold(0, (sum, i) => sum + i.qty);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text('Bill · $table')),
      body: open.isEmpty
          ? const Center(child: Text('Bill settled'))
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (split) ...[
                      Text('Orders on this table', style: theme.textTheme.titleMedium),
                      const Text('Untick orders to bill them separately.', style: TextStyle(color: Colors.grey)),
                      const SizedBox(height: 4),
                      for (final o in open)
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          value: !_excluded.contains(o.id),
                          onChanged: (v) => setState(() => v == true ? _excluded.remove(o.id) : _excluded.add(o.id)),
                          title: Text('Order #${o.number}  ·  ${formatMoney(o.total)}'),
                          subtitle: Text(
                            [
                              '${DateFormat.jm().format(o.createdAt)}${o.placedBy.isEmpty ? '' : ' · ${o.placedBy}'}',
                              o.items.map((i) => '${i.qty} ${i.name}').join(', '),
                            ].join('\n'),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                          isThreeLine: true,
                        ),
                      const Divider(height: 32),
                    ],
                    Text(s.settings.shopName, textAlign: TextAlign.center, style: theme.textTheme.headlineSmall),
                    Text(
                      'Table $table · ${DateFormat('d MMM y, h:mm a').format(DateTime.now())}',
                      textAlign: TextAlign.center,
                    ),
                    Text(
                      selected.isEmpty
                          ? 'No orders selected'
                          : 'Orders ${selected.map((o) => '#${o.number}').join(', ')}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.grey),
                    ),
                    const Divider(height: 32),
                    for (final i in lines.values)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            Expanded(child: Text(i.name, style: const TextStyle(fontSize: 16))),
                            SizedBox(width: 90, child: Text('${i.qty} × ${formatMoney(i.price)}')),
                            SizedBox(
                              width: 80,
                              child: Text(
                                formatMoney(i.total),
                                textAlign: TextAlign.right,
                                style: const TextStyle(fontSize: 16),
                              ),
                            ),
                          ],
                        ),
                      ),
                    const Divider(height: 32),
                    Row(
                      children: [
                        Text('Total ($qtyTotal items)', style: theme.textTheme.titleLarge),
                        const Spacer(),
                        Text(
                          formatMoney(total),
                          style: theme.textTheme.headlineSmall!.copyWith(fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    if (selected.length < open.length && selected.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          '${open.length - selected.length} other order(s) stay open on $table for a separate bill.',
                          style: TextStyle(color: theme.colorScheme.primary),
                        ),
                      ),
                    if (selected.any((o) => o.status.isActive))
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          'Some items are still in the kitchen.',
                          style: TextStyle(color: Colors.orange.shade800),
                        ),
                      ),
                  ],
                ),
              ),
            ),
      bottomNavigationBar: open.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    for (final m in paymentMethods) ...[
                      if (m != paymentMethods.first) const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton(
                          style: FilledButton.styleFrom(padding: const EdgeInsets.all(14)),
                          onPressed: selected.isEmpty ? null : () => _pay(m, selected, s.billFor(table).length),
                          child: Text('Paid · $m'),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
    );
  }

  Future<void> _pay(String method, List<Order> orders, int openCount) async {
    final table = widget.table;
    final total = orders.fold<double>(0, (sum, o) => sum + o.total);
    final partial = orders.length < openCount;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Received ${formatMoney(total)} by $method?'),
        content: Text(
          partial
              ? 'Orders ${orders.map((o) => '#${o.number}').join(', ')} will be marked as paid. The other orders stay open on $table.'
              : 'Table $table will be marked as paid and freed.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Back')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Confirm')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final client = ClientScope.read(context);
    final paid = await run(
      () => client.payOrders([for (final o in orders) o.id], method),
      success:
          '${partial ? 'Orders ${orders.map((o) => '#${o.number}').join(', ')}' : table} paid ${formatMoney(total)} ($method)',
    );
    if (!paid || !mounted) return;
    if (partial && widget.onlyOrderId == null) {
      // Show the remaining orders for the next bill.
      setState(_excluded.clear);
      return;
    }
    // Go back to the table if it still has open orders, otherwise to the
    // tables grid. Paying from the Billing list returns to that list.
    Navigator.popUntil(
      context,
      (r) => r.isFirst || r.settings.name == 'billing' || (partial && r.settings.name == TableScreen.routeName),
    );
  }
}
