import 'package:flutter/material.dart';

import '../models.dart';
import 'common.dart';

/// Add, edit, price and switch off menu items.
class MenuScreen extends StatelessWidget {
  const MenuScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final client = ClientScope.of(context);
    final s = client.state;
    final categories = [
      ...s.settings.categories,
      ...{for (final m in s.menu) m.category}.where((c) => !s.settings.categories.contains(c)),
    ];

    return Scaffold(
      drawer: const AppDrawer(current: 'menu'),
      appBar: AppBar(title: const Text('Menu')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showMenuItemEditor(context, null),
        icon: const Icon(Icons.add),
        label: const Text('Add item'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 90),
        children: [
          const ConnectionBanner(),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(
              'Tip: switch an item off when it runs out — waiters will see "Not available".',
              style: TextStyle(color: Colors.grey),
            ),
          ),
          for (final c in categories) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
              child: Text(c, style: Theme.of(context).textTheme.titleMedium),
            ),
            for (final m in s.menu.where((m) => m.category == c))
              ListTile(
                title: Text(m.name, style: TextStyle(decoration: m.available ? null : TextDecoration.lineThrough)),
                subtitle: Text(formatMoney(m.price)),
                onTap: () => showMenuItemEditor(context, m),
                trailing: Switch(
                  value: m.available,
                  onChanged: (v) => run(() => client.saveMenuItem(m.copyWith(available: v))),
                ),
              ),
            if (!s.menu.any((m) => m.category == c))
              const ListTile(
                dense: true,
                title: Text('No items', style: TextStyle(color: Colors.grey)),
              ),
          ],
        ],
      ),
    );
  }
}

Future<void> showMenuItemEditor(BuildContext context, MenuItem? item) {
  final client = ClientScope.read(context);
  final categories = client.state.settings.categories;
  final name = TextEditingController(text: item?.name ?? '');
  final price = TextEditingController(
    text: item == null ? '' : item.price.toStringAsFixed(item.price % 1 == 0 ? 0 : 2),
  );
  var category = item?.category ?? (categories.isEmpty ? 'Other' : categories.first);
  final formKey = GlobalKey<FormState>();

  return showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text(item == null ? 'New item' : 'Edit item'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: name,
                autofocus: item == null,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Name'),
                validator: (v) => v == null || v.trim().isEmpty ? 'Enter a name' : null,
              ),
              TextFormField(
                controller: price,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Price', prefixText: '₹ '),
                validator: (v) => double.tryParse(v ?? '') == null ? 'Enter a price' : null,
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: category,
                decoration: const InputDecoration(labelText: 'Category'),
                items: [
                  for (final c in {...categories, category}) DropdownMenuItem(value: c, child: Text(c)),
                ],
                onChanged: (v) => setState(() => category = v!),
              ),
            ],
          ),
        ),
        actions: [
          if (item != null)
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              onPressed: () async {
                if (await run(() => client.deleteMenuItem(item.id)) && ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Delete'),
            ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              if (!formKey.currentState!.validate()) return;
              final saved = MenuItem(
                id: item?.id ?? '',
                name: name.text.trim(),
                category: category,
                price: double.parse(price.text),
                available: item?.available ?? true,
              );
              if (await run(() => client.saveMenuItem(saved)) && ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
}
