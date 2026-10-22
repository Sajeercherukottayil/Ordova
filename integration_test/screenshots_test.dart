// Takes portfolio / README screenshots of Ordova: the real screens against a
// real kitchen server, seeded with a busy café shift.
//
//   flutter test integration_test/screenshots_test.dart -d windows \
//     --dart-define=OUT_DIR=<folder>
//
// Writes one PNG per screen to <OUT_DIR> (phone shots at 3x, tablet at 2x),
// plus hero.png with the waiter phone and kitchen tablet side by side.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ordova/client/ordova_client.dart';
import 'package:ordova/models.dart';
import 'package:ordova/server/kitchen_server.dart';
import 'package:ordova/services/prefs.dart';
import 'package:ordova/ui/billing_screen.dart';
import 'package:ordova/ui/common.dart';
import 'package:ordova/ui/kitchen_screen.dart';
import 'package:ordova/ui/menu_screen.dart';
import 'package:ordova/ui/role_screen.dart';
import 'package:ordova/ui/sales_screen.dart';
import 'package:ordova/ui/settings_screen.dart';
import 'package:ordova/ui/tables_screen.dart';
import 'package:ordova/ui/take_order_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _outDir = String.fromEnvironment('OUT_DIR');
const _phone = Size(390, 844);
const _tablet = Size(1280, 800);
const _coffee = Color(0xFF6F4E37);

final _shotKey = GlobalKey();
var _nav = GlobalKey<NavigatorState>();
final _screen = ValueNotifier<Widget>(const SizedBox.shrink());

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('screenshots', (tester) async {
    SharedPreferences.setMockInitialValues({'role': 'waiter', 'staffName': 'Rahul'});
    await Prefs.init();
    final dataDir = await Directory.systemTemp.createTemp('ordova_shots');
    await KitchenServer.instance.start(dataDir: dataDir);
    final client = OrdovaClient()..connect('127.0.0.1');
    Directory(_outDir).createSync(recursive: true);

    Future<void> wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));
    Future<void> until(bool Function() cond) async {
      for (var i = 0; i < 200 && !cond(); i++) {
        await wait(25);
      }
      expect(cond(), isTrue);
    }

    try {
      await until(() => client.hasState);

      // ------------------------------------------------------------ seed
      MenuItem menu(String name) => client.state.menu.firstWhere((m) => m.name == name);
      OrderItem item(String name, int qty, {String note = '', bool done = false}) {
        final m = menu(name);
        return OrderItem(menuId: m.id, name: m.name, price: m.price, qty: qty, note: note, done: done);
      }

      Future<Order> place(String table, List<OrderItem> items, {String note = '', String by = 'Rahul'}) async {
        final before = client.state.nextOrderNumber;
        await client.placeOrder(table: table, items: items, note: note, placedBy: by);
        await until(() => client.state.orders.any((o) => o.number == before));
        return client.state.orders.firstWhere((o) => o.number == before);
      }

      Future<void> status(Order o, OrderStatus s) async {
        await client.setStatus(o.id, s);
        await until(() => client.state.orders.firstWhere((x) => x.id == o.id).status == s);
      }

      Future<void> pay(String table, String method) async {
        await client.payTable(table, method);
        await until(() => client.state.billFor(table).isEmpty);
      }

      // Earlier in the day: settled bills for the sales report.
      final earlier = [
        ('T1', [item('Masala Tea', 2), item('Samosa', 4)], 'Cash'),
        ('T2', [item('Cappuccino', 2), item('Cheese Burger', 2), item('French Fries', 1)], 'UPI'),
        ('T4', [item('Cold Coffee', 3), item('Sandwich', 2)], 'Card'),
        ('Parcel', [item('Chicken Burger', 2), item('Mango Shake', 2)], 'UPI'),
        ('T6', [item('Tea', 4), item('Puffs', 4)], 'Cash'),
        ('T3', [item('Ginger Tea', 2), item('Veg Burger', 2), item('Lime Juice', 2)], 'UPI'),
        ('T7', [item('Coffee', 3), item('Samosa', 6), item('Orange Juice', 1)], 'UPI'),
      ];
      for (final (table, items, method) in earlier) {
        final o = await place(table, items);
        await status(o, OrderStatus.served);
        await pay(table, method);
      }

      // Right now: a busy floor.
      final t1 = await place('T1', [item('Coffee', 2), item('Sandwich', 2), item('Samosa', 2)], by: 'Anu');
      await status(t1, OrderStatus.served);
      final t2 = await place('T2', [item('Cappuccino', 1), item('Cheese Burger', 1), item('French Fries', 2)]);
      await status(t2, OrderStatus.preparing);
      await client.toggleItem(t2.id, 0);
      final t5 = await place('T5', [item('Mango Shake', 2), item('Veg Burger', 2)], by: 'Anu');
      await status(t5, OrderStatus.ready);
      await place('T3', [
        item('Tea', 2, note: 'Less sugar'),
        item('Veg Burger', 1, note: 'No onion'),
        item('French Fries', 1),
      ]);
      await place('Parcel', [item('Cold Coffee', 1), item('Samosa', 3)], note: 'Pack separately', by: 'Anu');
      await place('T7', [item('Masala Tea', 3), item('Puffs', 2)]);
      await wait(300);

      // ----------------------------------------------------------- helpers
      await tester.pumpWidget(ValueListenableBuilder(valueListenable: _screen, builder: (_, w, _) => w));
      Future<void> show(Size size, Widget home, {DeviceRole role = DeviceRole.waiter}) async {
        await Prefs.instance.setRole(role);
        // A fresh navigator each time: reusing the key would carry over the
        // previous screen's route stack.
        _nav = GlobalKey<NavigatorState>();
        _screen.value = _Shot(key: UniqueKey(), size: size, client: client, home: home);
        await wait(1200);
      }

      Future<void> push(Widget page) async {
        _nav.currentState!.push(MaterialPageRoute(builder: (_) => page));
        await wait(1200);
      }

      Future<void> tap(Finder f) async {
        await tester.tap(f.hitTestable().first);
        await wait(1200);
      }

      Future<void> shot(String name, {double ratio = 3}) async {
        final boundary = _shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: ratio);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        File('$_outDir/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
        debugPrint('wrote $name.png');
      }

      Finder menuRow(String name) => find.widgetWithText(ListTile, name);

      // ------------------------------------------------------------- shots
      await show(_phone, RoleScreen(onSelected: (_) {}));
      await shot('01_role');

      await show(_phone, const TablesScreen());
      await shot('02_tables');

      await push(const TakeOrderScreen(table: 'T4'));
      await tap(find.descendant(of: menuRow('Masala Tea'), matching: find.byIcon(Icons.add)));
      await tap(find.descendant(of: menuRow('Masala Tea'), matching: find.byIcon(Icons.add_circle)));
      await tap(find.descendant(of: menuRow('Ginger Tea'), matching: find.byIcon(Icons.add)));
      await shot('03_take_order');
      await tap(find.widgetWithText(Tab, 'Snacks'));
      await tap(find.descendant(of: menuRow('Samosa'), matching: find.byIcon(Icons.add)));
      await tap(find.descendant(of: menuRow('Samosa'), matching: find.byIcon(Icons.add_circle)));
      await tap(find.descendant(of: menuRow('Sandwich'), matching: find.byIcon(Icons.add)));
      await tap(find.text('Review & send'));
      await shot('04_review_order');

      await show(_phone, const TablesScreen());
      await push(const TableScreen(table: 'T5'));
      await shot('05_table_ready');

      await show(_phone, const TablesScreen());
      await push(const BillScreen(table: 'T1'));
      await shot('06_bill');

      await show(_phone, const SalesScreen());
      await shot('07_sales');

      await show(_phone, const MenuScreen());
      await shot('08_menu');

      await show(_phone, const SettingsScreen());
      await shot('09_settings');

      await show(_phone, const TablesScreen());
      await tap(find.byTooltip('Open navigation menu'));
      await shot('10_drawer');

      await show(_tablet, const KitchenScreen(), role: DeviceRole.kitchen);
      await shot('11_kitchen', ratio: 2);

      // Hero: both devices side by side.
      await Prefs.instance.setRole(DeviceRole.waiter);
      _screen.value = _Hero(client: client);
      await wait(1200);
      await shot('hero', ratio: 1);
    } finally {
      client.dispose();
      await KitchenServer.instance.stop();
      await dataDir.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}

ThemeData get _theme => ThemeData(
  colorScheme: ColorScheme.fromSeed(seedColor: _coffee, primary: _coffee),
  appBarTheme: const AppBarTheme(backgroundColor: _coffee, foregroundColor: Colors.white),
  cardTheme: const CardThemeData(margin: EdgeInsets.zero),
);

/// One device-sized app, scaled to fit the test window.
class _Shot extends StatelessWidget {
  const _Shot({super.key, required this.size, required this.client, required this.home});
  final Size size;
  final OrdovaClient client;
  final Widget home;

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.ltr,
    child: ColoredBox(
      color: Colors.black,
      child: FittedBox(
        child: RepaintBoundary(
          key: _shotKey,
          child: SizedBox.fromSize(
            size: size,
            child: _Pane(size: size, client: client, home: home, navigatorKey: _nav),
          ),
        ),
      ),
    ),
  );
}

class _Pane extends StatelessWidget {
  const _Pane({required this.size, required this.client, required this.home, this.navigatorKey, this.messengerKey});
  final Size size;
  final OrdovaClient client;
  final Widget home;
  final GlobalKey<NavigatorState>? navigatorKey;
  final GlobalKey<ScaffoldMessengerState>? messengerKey;

  @override
  Widget build(BuildContext context) => ClientScope(
    client: client,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      scaffoldMessengerKey: messengerKey ?? scaffoldMessengerKey,
      theme: _theme,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(size: size, padding: EdgeInsets.zero, viewPadding: EdgeInsets.zero),
        child: child!,
      ),
      home: home,
    ),
  );
}

class _Hero extends StatelessWidget {
  const _Hero({required this.client});
  final OrdovaClient client;

  static const _stage = Size(2400, 1350);
  static const _heroPhone = Size(390, 844);
  static const _heroTablet = Size(1280, 800);

  @override
  Widget build(BuildContext context) {
    Widget device(String label, IconData icon, Size size, double radius, Widget child) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF111111),
            borderRadius: BorderRadius.circular(radius + 16),
            boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 50, offset: Offset(0, 20))],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: SizedBox.fromSize(size: size, child: child),
          ),
        ),
        const SizedBox(height: 20),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white70, size: 28),
            const SizedBox(width: 10),
            Text(label, style: const TextStyle(color: Colors.white70, fontSize: 24)),
          ],
        ),
      ],
    );

    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: Colors.black,
        child: FittedBox(
          child: RepaintBoundary(
            key: _shotKey,
            child: SizedBox.fromSize(
              size: _stage,
              child: Material(
                type: MaterialType.transparency,
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF2A1C13), Color(0xFF5A3E2E)],
                    ),
                  ),
                  child: Column(
                    children: [
                      const SizedBox(height: 70),
                      const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.local_cafe, size: 72, color: Color(0xFFE8C9A7)),
                          SizedBox(width: 20),
                          Text(
                            'Ordova',
                            style: TextStyle(color: Colors.white, fontSize: 76, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Order taking and kitchen management for a small café  ·  runs on local Wi-Fi, no internet',
                        style: TextStyle(color: Color(0xFFE8C9A7), fontSize: 30),
                      ),
                      const SizedBox(height: 60),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          device(
                            'Waiter phone',
                            Icons.room_service,
                            _heroPhone,
                            44,
                            _Pane(size: _heroPhone, client: client, home: const TablesScreen()),
                          ),
                          const SizedBox(width: 90),
                          device(
                            'Kitchen tablet',
                            Icons.soup_kitchen,
                            _heroTablet,
                            30,
                            _Pane(
                              size: _heroTablet,
                              client: client,
                              home: const KitchenScreen(),
                              messengerKey: GlobalKey<ScaffoldMessengerState>(),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
