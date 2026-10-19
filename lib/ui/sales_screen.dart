import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models.dart';
import 'common.dart';

/// Daily sales: revenue, payment split, best sellers, busy hours.
class SalesScreen extends StatefulWidget {
  const SalesScreen({super.key});

  @override
  State<SalesScreen> createState() => _SalesScreenState();
}

class _SalesScreenState extends State<SalesScreen> {
  DateTime _day = DateUtils.dateOnly(DateTime.now());

  @override
  Widget build(BuildContext context) {
    final s = ClientScope.of(context).state;
    final theme = Theme.of(context);
    final paid = s.orders.where((o) => o.paidAt != null && DateUtils.isSameDay(o.paidAt, _day)).toList();
    final cancelled = s.orders
        .where((o) => o.status == OrderStatus.cancelled && DateUtils.isSameDay(o.createdAt, _day))
        .length;
    final revenue = paid.fold<double>(0, (sum, o) => sum + o.total);
    final bills = paid.map((o) => '${o.table}|${o.paidAt}').toSet().length;

    final byMethod = <String, double>{};
    final byItem = <String, (int, double)>{};
    final byCategory = <String, double>{};
    final byHour = List<double>.filled(24, 0);
    final categoryOf = {for (final m in s.menu) m.id: m.category};
    for (final o in paid) {
      byMethod.update(o.paymentMethod ?? 'Cash', (v) => v + o.total, ifAbsent: () => o.total);
      byHour[o.createdAt.hour] += o.total;
      for (final i in o.items) {
        final prev = byItem[i.name] ?? (0, 0.0);
        byItem[i.name] = (prev.$1 + i.qty, prev.$2 + i.total);
        byCategory.update(categoryOf[i.menuId] ?? 'Other', (v) => v + i.total, ifAbsent: () => i.total);
      }
    }
    final topItems = byItem.entries.toList()..sort((a, b) => b.value.$1.compareTo(a.value.$1));
    final maxHour = byHour.reduce((a, b) => a > b ? a : b);
    final openBills = s.orders.where((o) => o.isBillable).fold<double>(0, (sum, o) => sum + o.total);
    final isToday = DateUtils.isSameDay(_day, DateTime.now());

    Widget stat(String label, String value, IconData icon) => Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: theme.colorScheme.primary),
              const SizedBox(height: 6),
              Text(value, style: theme.textTheme.titleLarge!.copyWith(fontWeight: FontWeight.bold)),
              Text(label, style: theme.textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );

    Widget section(String title, List<Widget> children) => Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );

    Widget bar(String label, double value, double max, String trailing) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(width: 110, child: Text(label, overflow: TextOverflow.ellipsis)),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(value: max == 0 ? 0 : value / max, minHeight: 14),
            ),
          ),
          SizedBox(width: 80, child: Text(trailing, textAlign: TextAlign.right)),
        ],
      ),
    );

    return Scaffold(
      drawer: const AppDrawer(current: 'sales'),
      appBar: AppBar(title: const Text('Sales report')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 700),
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.chevron_left),
                    onPressed: () => setState(() => _day = _day.subtract(const Duration(days: 1))),
                  ),
                  Expanded(
                    child: TextButton(
                      onPressed: () async {
                        final d = await showDatePicker(
                          context: context,
                          initialDate: _day,
                          firstDate: DateTime.now().subtract(const Duration(days: 90)),
                          lastDate: DateTime.now(),
                        );
                        if (d != null) setState(() => _day = d);
                      },
                      child: Text(
                        isToday
                            ? 'Today · ${DateFormat('d MMM y').format(_day)}'
                            : DateFormat('EEE, d MMM y').format(_day),
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.chevron_right),
                    onPressed: isToday ? null : () => setState(() => _day = _day.add(const Duration(days: 1))),
                  ),
                ],
              ),
              Row(
                children: [
                  stat('Sales', formatMoney(revenue), Icons.currency_rupee),
                  const SizedBox(width: 8),
                  stat('Bills', '$bills', Icons.receipt),
                  const SizedBox(width: 8),
                  stat('Avg bill', formatMoney(bills == 0 ? 0 : revenue / bills), Icons.trending_up),
                ],
              ),
              if (isToday && openBills > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '+ ${formatMoney(openBills)} in open bills not yet paid',
                    style: TextStyle(color: Colors.orange.shade800),
                  ),
                ),
              if (cancelled > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('$cancelled cancelled order(s)', style: const TextStyle(color: Colors.grey)),
                ),
              if (paid.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: Text('No paid bills on this day')),
                )
              else ...[
                section('Payment methods', [
                  for (final e in byMethod.entries) bar(e.key, e.value, revenue, formatMoney(e.value)),
                ]),
                section('By category', [
                  for (final e in byCategory.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
                    bar(e.key, e.value, revenue, formatMoney(e.value)),
                ]),
                section('Best sellers', [
                  for (final e in topItems.take(10))
                    bar(
                      e.key,
                      e.value.$1.toDouble(),
                      topItems.first.value.$1.toDouble(),
                      '${e.value.$1} · ${formatMoney(e.value.$2)}',
                    ),
                ]),
                section('Busy hours', [
                  for (var h = 0; h < 24; h++)
                    if (byHour[h] > 0)
                      bar(DateFormat.j().format(DateTime(2000, 1, 1, h)), byHour[h], maxHour, formatMoney(byHour[h])),
                ]),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
