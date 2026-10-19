import 'package:flutter/material.dart';

import '../services/prefs.dart';

class RoleScreen extends StatelessWidget {
  const RoleScreen({super.key, required this.onSelected});
  final ValueChanged<DeviceRole> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget option(DeviceRole role, IconData icon, String title, String subtitle) => Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => onSelected(role),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Icon(icon, size: 48, color: theme.colorScheme.primary),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleLarge),
                    const SizedBox(height: 4),
                    Text(subtitle, style: theme.textTheme.bodyMedium),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(24),
              children: [
                Icon(Icons.local_cafe, size: 72, color: theme.colorScheme.primary),
                const SizedBox(height: 8),
                Text('Ordova', textAlign: TextAlign.center, style: theme.textTheme.displaySmall),
                const SizedBox(height: 4),
                const Text('What is this device used for?', textAlign: TextAlign.center),
                const SizedBox(height: 32),
                option(
                  DeviceRole.kitchen,
                  Icons.soup_kitchen,
                  'Kitchen',
                  'Main device. Receives orders and stores all data. Set this up first and keep it on Wi-Fi.',
                ),
                const SizedBox(height: 16),
                option(
                  DeviceRole.waiter,
                  Icons.room_service,
                  'Waiter',
                  'Takes orders at tables and sends them to the kitchen.',
                ),
                const SizedBox(height: 24),
                Text(
                  'All devices must be on the same Wi-Fi.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
