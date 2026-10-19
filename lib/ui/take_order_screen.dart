import 'package:flutter/material.dart';

import '../models.dart';
import '../services/prefs.dart';
import 'common.dart';

class _CartLine {
  int qty;
  String note = '';
  _CartLine(this.qty);
}

/// Pick items from the menu for a table and send them to the kitchen.
/// With [editing], changes an order that was already sent.
class TakeOrderScreen extends StatefulWidget {
  const TakeOrderScreen({super.key, required this.table, this.editing});
  final String table;
  final Order? editing;

  @override
  State<TakeOrderScreen> createState() => _TakeOrderScreenState();
}

class _TakeOrderScreenState extends State<TakeOrderScreen> {
  final _cart = <String, _CartLine>{}; // menuId -> line
  final _search = TextEditingController();
  String _orderNote = '';
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    final order = widget.editing;
    if (order == null) return;
    _orderNote = order.note;
    for (final item in order.items) {
      final line = _cart.putIfAbsent(item.menuId, () => _CartLine(0));
      line.qty += item.qty;
      if (item.note.isNotEmpty) line.note = line.note.isEmpty ? item.note : '${line.note}, ${item.note}';
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _add(MenuItem m, int delta) {
    setState(() {
      final line = _cart.putIfAbsent(m.id, () => _CartLine(0));
      line.qty += delta;
      if (line.qty <= 0) _cart.remove(m.id);
    });
  }

  Future<void> _editNote(MenuItem m) async {
    final line = _cart[m.id];
    final text = await _askText(
      context,
      'Note for ${m.name}',
      line?.note ?? '',
      hint: 'e.g. less sugar, no onion, extra cheese',
      suggestions: const ['Less sugar', 'No sugar', 'Strong', 'Extra hot', 'No ice', 'Spicy'],
    );
    if (text == null) return;
    setState(() {
      (_cart[m.id] ??= _CartLine(1)).note = text;
    });
  }

  List<OrderItem> _items(List<MenuItem> menu) => [
    for (final e in _cart.entries)
      // Items already on an edited order keep the name and price they were
      // ordered at, even if the menu changed since.
      if (widget.editing?.items.where((i) => i.menuId == e.key).firstOrNull case final old?)
        OrderItem(menuId: old.menuId, name: old.name, price: old.price, qty: e.value.qty, note: e.value.note)
      else if (menu.where((m) => m.id == e.key).firstOrNull case final m?)
        OrderItem(menuId: m.id, name: m.name, price: m.price, qty: e.value.qty, note: e.value.note),
  ];

  Future<void> _send(List<OrderItem> items) async {
    setState(() => _sending = true);
    final client = ClientScope.read(context);
    final editing = widget.editing;
    final ok = await run(
      () => editing != null
          ? client.editOrder(editing.id, items: items, note: _orderNote)
          : client.placeOrder(table: widget.table, items: items, note: _orderNote, placedBy: Prefs.instance.staffName),
      success: editing != null
          ? 'Order #${editing.number} updated — kitchen notified'
          : 'Order sent to kitchen for ${widget.table}',
    );
    if (!mounted) return;
    setState(() => _sending = false);
    if (ok) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final s = ClientScope.of(context).state;
    final categories = [
      ...s.settings.categories,
      ...{for (final m in s.menu) m.category}.where((c) => !s.settings.categories.contains(c)),
    ];
    final query = _search.text.trim().toLowerCase();
    final items = _items(s.menu);
    final count = items.fold(0, (sum, i) => sum + i.qty);
    final total = items.fold<double>(0, (sum, i) => sum + i.total);

    Widget menuList(Iterable<MenuItem> list) {
      final visible = list.toList();
      if (visible.isEmpty) return const Center(child: Text('No items'));
      return ListView.separated(
        padding: const EdgeInsets.only(bottom: 90),
        itemCount: visible.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (_, i) => _MenuRow(
          item: visible[i],
          line: _cart[visible[i].id],
          onAdd: () => _add(visible[i], 1),
          onRemove: () => _add(visible[i], -1),
          onNote: () => _editNote(visible[i]),
        ),
      );
    }

    return DefaultTabController(
      length: categories.length,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            widget.editing == null
                ? 'Order · ${widget.table}'
                : 'Edit order #${widget.editing!.number} · ${widget.table}',
          ),
          bottom: PreferredSize(
            preferredSize: Size.fromHeight(query.isEmpty ? 112 : 64),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: TextField(
                    controller: _search,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: 'Search menu',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: query.isEmpty
                          ? null
                          : IconButton(icon: const Icon(Icons.clear), onPressed: () => setState(() => _search.clear())),
                      filled: true,
                      fillColor: Colors.white,
                      isDense: true,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(30), borderSide: BorderSide.none),
                    ),
                  ),
                ),
                if (query.isEmpty)
                  TabBar(
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    labelColor: Colors.white,
                    unselectedLabelColor: Colors.white70,
                    indicatorColor: Colors.white,
                    tabs: [for (final c in categories) Tab(text: c)],
                  ),
              ],
            ),
          ),
        ),
        body: Column(
          children: [
            const ConnectionBanner(),
            Expanded(
              child: query.isNotEmpty
                  ? menuList(s.menu.where((m) => m.name.toLowerCase().contains(query)))
                  : TabBarView(children: [for (final c in categories) menuList(s.menu.where((m) => m.category == c))]),
            ),
          ],
        ),
        bottomNavigationBar: count == 0
            ? (widget.editing == null
                  ? null
                  : const SafeArea(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(
                          'The order is empty. To remove the whole order, go back and use "Cancel order".',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ))
            : SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: FilledButton(
                    style: FilledButton.styleFrom(padding: const EdgeInsets.all(16)),
                    onPressed: _sending ? null : () => _review(context),
                    child: Row(
                      children: [
                        Badge(label: Text('$count'), child: const Icon(Icons.shopping_bag)),
                        const SizedBox(width: 16),
                        Text(
                          widget.editing == null ? 'Review & send' : 'Review changes',
                          style: const TextStyle(fontSize: 16),
                        ),
                        const Spacer(),
                        Text(formatMoney(total), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  Future<void> _review(BuildContext context) async {
    final send = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final s = ClientScope.of(ctx).state;
          final items = _items(s.menu);
          final total = items.fold<double>(0, (sum, i) => sum + i.total);
          void change(VoidCallback f) {
            setState(f);
            setSheet(() {});
            if (_cart.isEmpty) Navigator.pop(ctx, false);
          }

          return ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.editing == null
                      ? 'Order for ${widget.table}'
                      : 'Order #${widget.editing!.number} · ${widget.table}',
                  style: Theme.of(ctx).textTheme.titleLarge,
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final item in items)
                        ListTile(
                          title: Text('${item.name}  ·  ${formatMoney(item.total)}'),
                          subtitle: item.note.isEmpty
                              ? null
                              : Text(item.note, style: TextStyle(color: Colors.deepOrange.shade700)),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.remove_circle_outline),
                                onPressed: () => change(() {
                                  final line = _cart[item.menuId]!;
                                  if (--line.qty <= 0) _cart.remove(item.menuId);
                                }),
                              ),
                              Text('${item.qty}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                              IconButton(
                                icon: const Icon(Icons.add_circle_outline),
                                onPressed: () => change(() => _cart[item.menuId]!.qty++),
                              ),
                            ],
                          ),
                        ),
                      ListTile(
                        leading: const Icon(Icons.sticky_note_2_outlined),
                        title: Text(_orderNote.isEmpty ? 'Add note for kitchen' : _orderNote),
                        onTap: () async {
                          final t = await _askText(
                            ctx,
                            'Note for whole order',
                            _orderNote,
                            hint: 'e.g. serve together, birthday',
                          );
                          if (t != null) change(() => _orderNote = t);
                        },
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(padding: const EdgeInsets.all(16)),
                      onPressed: () => Navigator.pop(ctx, true),
                      icon: Icon(widget.editing == null ? Icons.send : Icons.save),
                      label: Text(
                        '${widget.editing == null ? 'Send to kitchen' : 'Save changes'}  ·  ${formatMoney(total)}',
                        style: const TextStyle(fontSize: 16),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
    if (send == true && mounted) {
      _send(_items(ClientScope.read(this.context).state.menu));
    }
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.item,
    required this.line,
    required this.onAdd,
    required this.onRemove,
    required this.onNote,
  });
  final MenuItem item;
  final _CartLine? line;
  final VoidCallback onAdd, onRemove, onNote;

  @override
  Widget build(BuildContext context) {
    final qty = line?.qty ?? 0;
    return ListTile(
      enabled: item.available,
      onTap: item.available ? onAdd : null,
      onLongPress: item.available ? onNote : null,
      title: Text(item.name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w500)),
      subtitle: Text(
        item.available
            ? [formatMoney(item.price), if (line?.note.isNotEmpty == true) line!.note].join('  ·  ')
            : 'Not available now',
      ),
      trailing: !item.available
          ? null
          : qty == 0
          ? IconButton.filledTonal(onPressed: onAdd, icon: const Icon(Icons.add))
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(onPressed: onNote, icon: const Icon(Icons.edit_note), tooltip: 'Add note'),
                IconButton(onPressed: onRemove, icon: const Icon(Icons.remove_circle_outline)),
                SizedBox(
                  width: 28,
                  child: Text(
                    '$qty',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
                IconButton(onPressed: onAdd, icon: const Icon(Icons.add_circle)),
              ],
            ),
    );
  }
}

Future<String?> _askText(
  BuildContext context,
  String title,
  String initial, {
  String? hint,
  List<String> suggestions = const [],
}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: controller,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(hintText: hint),
            onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
          ),
          if (suggestions.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final sgt in suggestions)
                  ActionChip(
                    label: Text(sgt),
                    onPressed: () {
                      final cur = controller.text.trim();
                      controller.text = cur.isEmpty ? sgt : '$cur, $sgt';
                    },
                  ),
              ],
            ),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, ''), child: const Text('Clear')),
        FilledButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: const Text('Save')),
      ],
    ),
  );
}
