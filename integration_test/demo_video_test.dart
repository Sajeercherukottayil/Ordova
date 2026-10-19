// Records a demo video of Ordova: a waiter phone and the kitchen tablet side
// by side, both running the real screens against a real kitchen server.
//
//   flutter test integration_test/demo_video_test.dart -d windows \
//     --dart-define=FFMPEG=<path to ffmpeg.exe> --dart-define=OUT_DIR=<folder>
//
// Writes <OUT_DIR>/ordova_demo_silent.mp4 and <OUT_DIR>/sounds.json (when the
// alert tones and narration lines start) so demo/add_sounds.py can mix them in.
// With --dart-define=NARRATION=<voice.json> (line -> length in ms, made by
// demo/make_voice.py) each step waits for the previous line to finish.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ordova/client/ordova_client.dart';
import 'package:ordova/server/kitchen_server.dart';
import 'package:ordova/services/alerts.dart';
import 'package:ordova/services/prefs.dart';
import 'package:ordova/ui/common.dart';
import 'package:ordova/ui/kitchen_screen.dart';
import 'package:ordova/ui/tables_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _ffmpeg = String.fromEnvironment('FFMPEG');
const _outDir = String.fromEnvironment('OUT_DIR');
const _narration = String.fromEnvironment('NARRATION');
const _fps = 25;
const _stage = Size(1920, 1080);
const _phone = Size(390, 800);
const _tablet = Size(1260, 800);
const _coffee = Color(0xFF6F4E37);

final _stageKey = GlobalKey();
final _waiterKey = GlobalKey();
final _kitchenKey = GlobalKey();
final _kitchenMessenger = GlobalKey<ScaffoldMessengerState>();
final _caption = ValueNotifier<String>('');
final _card = ValueNotifier<Widget?>(null);
final _marks = ValueNotifier<List<(int, Offset)>>([]);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('demo video', (tester) async {
    SharedPreferences.setMockInitialValues({'role': 'kitchen', 'staffName': 'Rahul'});
    await Prefs.init();
    final dataDir = await Directory.systemTemp.createTemp('ordova_demo');
    await KitchenServer.instance.start(dataDir: dataDir);
    final waiter = OrdovaClient()..connect('127.0.0.1');
    final kitchen = OrdovaClient()..connect('127.0.0.1');

    final clock = Stopwatch();
    final sounds = <Map<String, Object>>[];
    // Same alerts as the kitchen device in main.dart.
    kitchen.events.listen((e) {
      final message = switch (e.kind) {
        'new_order' => 'New order #${e.number} — ${e.table}',
        'edited' => 'Order #${e.number} (${e.table}) was CHANGED — check the ticket',
        'cancelled' => 'Order #${e.number} (${e.table}) was CANCELLED',
        _ => null,
      };
      if (message == null) return;
      sounds.add({'kind': 'new_order', 'ms': clock.elapsedMilliseconds});
      Alerts.newOrder();
      _kitchenMessenger.currentState
        ?..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor: e.kind == 'cancelled' ? Colors.red.shade700 : null,
            behavior: SnackBarBehavior.floating,
          ),
        );
    });
    waiter.events.where((e) => e.kind == 'ready').listen((e) {
      sounds.add({'kind': 'ready', 'ms': clock.elapsedMilliseconds});
      Alerts.ready();
      showMessage('Order #${e.number} for ${e.table} is READY — pick up from kitchen');
    });

    await tester.pumpWidget(_DemoApp(waiter: waiter, kitchen: kitchen));
    Future<void> wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));
    while (!waiter.hasState || !kitchen.hasState) {
      await wait(50);
    }

    // ------------------------------------------------------------ recording
    final ffmpeg = await Process.start(_ffmpeg, [
      '-y', '-f', 'rawvideo', '-pix_fmt', 'rgba', '-s', '${_stage.width.toInt()}x${_stage.height.toInt()}',
      '-r', '$_fps', '-i', '-', //
      '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '18', '-pix_fmt', 'yuv420p',
      '$_outDir/ordova_demo_silent.mp4',
    ]);
    ffmpeg.stdout.drain<void>();
    ffmpeg.stderr.drain<void>();
    var recording = true;
    var written = 0;
    Uint8List? last;
    Future<void> record() async {
      final boundary = _stageKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      clock.start();
      while (recording) {
        await SchedulerBinding.instance.endOfFrame;
        try {
          final image = await boundary.toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
          image.dispose();
          last = data!.buffer.asUint8List();
        } catch (e) {
          // Caught mid-frame; reuse the previous frame.
          debugPrint('frame skipped: $e');
        }
        final target = clock.elapsedMilliseconds * _fps ~/ 1000 + 1;
        while (last != null && written < target) {
          ffmpeg.stdin.add(last!);
          written++;
        }
        await ffmpeg.stdin.flush();
        final sleep = (written * 1000 / _fps - clock.elapsedMilliseconds).round();
        if (sleep > 0) await wait(sleep);
      }
    }

    final recorder = record();

    // -------------------------------------------------------------- helpers
    Finder inWaiter(Finder f) => find.descendant(of: find.byKey(_waiterKey), matching: f);
    Finder inKitchen(Finder f) => find.descendant(of: find.byKey(_kitchenKey), matching: f);
    Finder ticket(int number) => inKitchen(find.byWidgetPredicate((w) => w is TicketCard && w.order.number == number));
    Finder inTicket(int number, Finder f) => find.descendant(of: ticket(number), matching: f);
    Finder menuRow(String name) => inWaiter(find.widgetWithText(ListTile, name));

    var markId = 0;
    Future<void> tap(Finder f, {int after = 900}) async {
      debugPrint('tap $f at ${clock.elapsedMilliseconds}ms');
      final pos = tester.getCenter(f.hitTestable().first);
      final stageBox = _stageKey.currentContext!.findRenderObject()! as RenderBox;
      final id = markId++;
      _marks.value = [..._marks.value, (id, stageBox.globalToLocal(pos))];
      Future<void>.delayed(const Duration(milliseconds: 700), () {
        _marks.value = _marks.value.where((m) => m.$1 != id).toList();
      });
      await wait(280);
      await tester.tapAt(pos);
      await wait(after);
    }

    Future<void> scroll(Finder f, double dy) async {
      await tester.timedDrag(f, Offset(0, dy), const Duration(milliseconds: 700));
      await wait(700);
    }

    Future<void> type(Finder field, String text) async {
      for (var i = 1; i <= text.length; i++) {
        await tester.enterText(field, text.substring(0, i));
        await wait(90);
      }
      await wait(400);
    }

    final voice = _narration.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(File(_narration).readAsStringSync()) as Map<String, dynamic>;
    var voiceFreeAt = 0;
    Future<void> waitForVoice() async {
      final left = voiceFreeAt - clock.elapsedMilliseconds;
      if (left > 0) await wait(left);
    }

    Future<void> narrate(String line) async {
      await waitForVoice();
      sounds.add({'kind': 'voice', 'line': line, 'ms': clock.elapsedMilliseconds});
      voiceFreeAt = clock.elapsedMilliseconds + ((voice[line] as num?)?.toInt() ?? 0) + 350;
    }

    Future<void> say(String text, {int hold = 1200}) async {
      await waitForVoice();
      _caption.value = text;
      await narrate(text);
      await wait(hold);
    }

    Finder dialogField() => find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField));

    // --------------------------------------------------------------- script
    try {
      _card.value = const _TitleCard();
      await wait(800);
      await narrate('intro');
      await wait(3400);
      await waitForVoice();
      _card.value = null;
      await say('A waiter phone and the kitchen tablet, connected over the café Wi-Fi', hold: 3500);

      await say('The waiter taps a free table…');
      await tap(inWaiter(find.text('T3')), after: 1400);

      await say('…and adds items. Each item can carry a note for the kitchen.', hold: 800);
      await tap(find.descendant(of: menuRow('Tea'), matching: find.byIcon(Icons.add)), after: 600);
      await tap(find.descendant(of: menuRow('Tea'), matching: find.byIcon(Icons.add_circle)), after: 700);
      await tap(find.descendant(of: menuRow('Tea'), matching: find.byIcon(Icons.edit_note)), after: 900);
      await tap(inWaiter(find.widgetWithText(ActionChip, 'Less sugar')), after: 700);
      await tap(inWaiter(find.widgetWithText(FilledButton, 'Save')), after: 900);
      await tap(inWaiter(find.widgetWithText(Tab, 'Burgers')), after: 900);
      await tap(find.descendant(of: menuRow('Veg Burger'), matching: find.byIcon(Icons.add)), after: 700);
      await tap(inWaiter(find.widgetWithText(Tab, 'Snacks')), after: 900);
      await tap(find.descendant(of: menuRow('French Fries'), matching: find.byIcon(Icons.add)), after: 1000);

      await say('Review the order and send it to the kitchen', hold: 600);
      await tap(inWaiter(find.text('Review & send')), after: 1800);
      await tap(inWaiter(find.textContaining('Send to kitchen')), after: 600);
      await say('The kitchen beeps and the ticket shows up straight away', hold: 3500);

      await say('Take-away works too. Here is a parcel order with a note for the whole order', hold: 600);
      await scroll(inWaiter(find.byType(GridView)), -300);
      await tap(inWaiter(find.text('Parcel')), after: 1200);
      await tap(inWaiter(find.widgetWithText(Tab, 'Coffee')), after: 900);
      await tap(find.descendant(of: menuRow('Cold Coffee'), matching: find.byIcon(Icons.add)), after: 600);
      await tap(inWaiter(find.widgetWithText(Tab, 'Snacks')), after: 900);
      await tap(find.descendant(of: menuRow('Samosa'), matching: find.byIcon(Icons.add)), after: 500);
      await tap(find.descendant(of: menuRow('Samosa'), matching: find.byIcon(Icons.add_circle)), after: 800);
      await tap(inWaiter(find.text('Review & send')), after: 1500);
      await tap(inWaiter(find.text('Add note for kitchen')), after: 900);
      await type(inWaiter(dialogField()), 'Pack separately');
      await tap(inWaiter(find.widgetWithText(FilledButton, 'Save')), after: 1000);
      await tap(inWaiter(find.textContaining('Send to kitchen')), after: 2400);
      await scroll(inWaiter(find.byType(GridView)), 300);

      await say('T3 wants a samosa too. It is not cooked yet, so the waiter edits the order', hold: 400);
      await tap(inWaiter(find.text('T3')), after: 1400);
      await tap(inWaiter(find.text('#1')), after: 1400);
      await tap(inWaiter(find.text('Edit order')), after: 1400);
      await tap(inWaiter(find.widgetWithText(Tab, 'Snacks')), after: 900);
      await tap(find.descendant(of: menuRow('Samosa'), matching: find.byIcon(Icons.add)), after: 900);
      await tap(inWaiter(find.text('Review changes')), after: 1500);
      await tap(inWaiter(find.textContaining('Save changes')), after: 600);
      await say('The kitchen beeps again, and the ticket is marked EDITED', hold: 2500);
      await tap(inWaiter(find.byTooltip('Back')), after: 800);
      await tap(inWaiter(find.byTooltip('Back')), after: 1000);

      await say('The parcel customer cancels, so the waiter cancels that order', hold: 400);
      await scroll(inWaiter(find.byType(GridView)), -300);
      await tap(inWaiter(find.text('Parcel')), after: 1400);
      await tap(inWaiter(find.text('#2')), after: 1400);
      await tap(inWaiter(find.widgetWithText(OutlinedButton, 'Cancel order')), after: 1500);
      await tap(inWaiter(find.widgetWithText(FilledButton, 'Cancel order')), after: 600);
      await say('The kitchen is told at once, and the parcel ticket is removed', hold: 2500);
      await scroll(inWaiter(find.byType(GridView)), 300);

      await say('Now the cook starts the T3 ticket…');
      await tap(inTicket(1, find.text('Start')), after: 1500);
      await say('…and ticks off each item as it is done');
      final unticked = inTicket(1, find.byIcon(Icons.check_box_outline_blank));
      while (unticked.evaluate().isNotEmpty) {
        await tap(unticked, after: 1000);
      }
      await say('All items done, so the ticket goes Ready and the waiter phone rings', hold: 3800);

      await say('The waiter picks up, marks it served, and opens the bill', hold: 400);
      await tap(inWaiter(find.text('T3')), after: 1600);
      await tap(inWaiter(find.text('Picked up & served')), after: 1300);
      await tap(inWaiter(find.textContaining(RegExp(r'^Bill ₹'))), after: 2600);
      await say('Paid by UPI, and the table is free again', hold: 300);
      await tap(inWaiter(find.text('Paid · UPI')), after: 1200);
      await tap(inWaiter(find.text('Confirm')), after: 2500);

      // The sales report lives in the waiter's menu.
      await Prefs.instance.setRole(DeviceRole.waiter);
      await say('The owner can check the day\'s sales, behind a PIN', hold: 400);
      await tap(inWaiter(find.byTooltip('Open navigation menu')), after: 900);
      await tap(inWaiter(find.text('Sales report')), after: 1000);
      await type(inWaiter(dialogField()), '1234');
      await tap(inWaiter(find.text('Unlock')), after: 4500);

      _card.value = const _EndCard();
      await wait(700);
      await narrate('outro');
      await wait(4300);
      await waitForVoice();
      await wait(1500);
    } finally {
      // ------------------------------------------------------------- teardown
      recording = false;
      await recorder;
      await ffmpeg.stdin.close();
      final code = await ffmpeg.exitCode;
      File('$_outDir/sounds.json').writeAsStringSync(jsonEncode(sounds));
      waiter.dispose();
      kitchen.dispose();
      await KitchenServer.instance.stop();
      await dataDir.delete(recursive: true);
      expect(code, 0, reason: 'ffmpeg failed');
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}

// -------------------------------------------------------------------- stage

ThemeData get _theme => ThemeData(
  colorScheme: ColorScheme.fromSeed(seedColor: _coffee, primary: _coffee),
  appBarTheme: const AppBarTheme(backgroundColor: _coffee, foregroundColor: Colors.white),
  cardTheme: const CardThemeData(margin: EdgeInsets.zero),
);

class _DemoApp extends StatelessWidget {
  const _DemoApp({required this.waiter, required this.kitchen});
  final OrdovaClient waiter, kitchen;

  @override
  // No outer MaterialApp: dialogs use the root navigator, which must be the
  // pane's own so they open inside the device.
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.ltr,
    child: ColoredBox(
      color: Colors.black,
      child: FittedBox(
        child: SizedBox.fromSize(
          size: _stage,
          child: RepaintBoundary(
            key: _stageKey,
            child: _Stage(waiter: waiter, kitchen: kitchen),
          ),
        ),
      ),
    ),
  );
}

class _Stage extends StatelessWidget {
  const _Stage({required this.waiter, required this.kitchen});
  final OrdovaClient waiter, kitchen;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF2A1C13), Color(0xFF4B3427)],
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 38,
            height: 90,
            child: ValueListenableBuilder(
              valueListenable: _caption,
              builder: (_, text, _) => AnimatedSwitcher(
                duration: const Duration(milliseconds: 350),
                child: Text(
                  text,
                  key: ValueKey(text),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 38, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 140,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Device(
                  label: 'Waiter phone',
                  icon: Icons.room_service,
                  size: _phone,
                  radius: 44,
                  child: _Pane(
                    key: _waiterKey,
                    size: _phone,
                    client: waiter,
                    messengerKey: scaffoldMessengerKey,
                    home: const TablesScreen(),
                  ),
                ),
                const SizedBox(width: 70),
                _Device(
                  label: 'Kitchen tablet',
                  icon: Icons.soup_kitchen,
                  size: _tablet,
                  radius: 30,
                  child: _Pane(
                    key: _kitchenKey,
                    size: _tablet,
                    client: kitchen,
                    messengerKey: _kitchenMessenger,
                    home: const KitchenScreen(),
                  ),
                ),
              ],
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: ValueListenableBuilder(
                valueListenable: _marks,
                builder: (_, marks, _) => Stack(
                  children: [
                    for (final (id, pos) in marks)
                      Positioned(key: ValueKey(id), left: pos.dx - 34, top: pos.dy - 34, child: const _TapMark()),
                  ],
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: ValueListenableBuilder(
              valueListenable: _card,
              builder: (_, card, _) =>
                  AnimatedSwitcher(duration: const Duration(milliseconds: 600), child: card ?? const SizedBox.shrink()),
            ),
          ),
        ],
      ),
    );
  }
}

class _Device extends StatelessWidget {
  const _Device({
    required this.label,
    required this.icon,
    required this.size,
    required this.radius,
    required this.child,
  });
  final String label;
  final IconData icon;
  final Size size;
  final double radius;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF111111),
          borderRadius: BorderRadius.circular(radius + 14),
          boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 40, offset: Offset(0, 16))],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: SizedBox.fromSize(size: size, child: child),
        ),
      ),
      const SizedBox(height: 16),
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white70, size: 26),
          const SizedBox(width: 10),
          Text(label, style: const TextStyle(color: Colors.white70, fontSize: 22)),
        ],
      ),
    ],
  );
}

/// One device's app: its own client, navigator, snackbars and screen size.
class _Pane extends StatelessWidget {
  const _Pane({super.key, required this.size, required this.client, required this.messengerKey, required this.home});
  final Size size;
  final OrdovaClient client;
  final GlobalKey<ScaffoldMessengerState> messengerKey;
  final Widget home;

  @override
  Widget build(BuildContext context) => ClientScope(
    client: client,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: messengerKey,
      theme: _theme,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(size: size, padding: EdgeInsets.zero, viewPadding: EdgeInsets.zero),
        child: child!,
      ),
      home: home,
    ),
  );
}

class _TapMark extends StatelessWidget {
  const _TapMark();

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: const Duration(milliseconds: 650),
    builder: (_, t, _) => Opacity(
      opacity: (1 - t).clamp(0, 1) * 0.9 + 0.1,
      child: Transform.scale(
        scale: 0.5 + t * 0.7,
        child: Container(
          width: 68,
          height: 68,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withValues(alpha: 0.35 * (1 - t)),
            border: Border.all(color: Colors.white.withValues(alpha: 1 - t), width: 4),
          ),
        ),
      ),
    ),
  );
}

class _Card extends StatelessWidget {
  const _Card({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF2A1C13), Color(0xFF5A3E2E)],
      ),
    ),
    child: Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: children),
    ),
  );
}

class _TitleCard extends StatelessWidget {
  const _TitleCard();

  @override
  Widget build(BuildContext context) => const _Card(
    children: [
      Icon(Icons.local_cafe, size: 130, color: Color(0xFFE8C9A7)),
      SizedBox(height: 16),
      Text(
        'Ordova',
        style: TextStyle(color: Colors.white, fontSize: 110, fontWeight: FontWeight.bold),
      ),
      SizedBox(height: 12),
      Text('Order taking and kitchen management for a small café', style: TextStyle(color: Colors.white, fontSize: 38)),
      SizedBox(height: 18),
      Text(
        'Runs on the shop Wi-Fi  ·  no internet  ·  no account  ·  no monthly cost',
        style: TextStyle(color: Color(0xFFE8C9A7), fontSize: 28),
      ),
    ],
  );
}

class _EndCard extends StatelessWidget {
  const _EndCard();

  @override
  Widget build(BuildContext context) {
    Widget line(IconData icon, String text) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: const Color(0xFFE8C9A7), size: 36),
          const SizedBox(width: 18),
          SizedBox(
            width: 1000,
            child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 32)),
          ),
        ],
      ),
    );
    return _Card(
      children: [
        const Text(
          'Ordova',
          style: TextStyle(color: Colors.white, fontSize: 90, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 30),
        line(Icons.table_restaurant, 'Live table status: free, in kitchen, ready, unpaid'),
        line(Icons.soup_kitchen, 'Kitchen board: New → Preparing → Ready, with beeps'),
        line(Icons.notifications_active, 'Ready alerts on every waiter phone'),
        line(Icons.edit_note, 'Edit or cancel orders, and the kitchen is told instantly'),
        line(Icons.receipt_long, 'Merged or split bills, paid by Cash / UPI / Card'),
        line(Icons.bar_chart, 'Daily sales, best sellers and busy hours'),
        line(Icons.wifi, 'All on local Wi-Fi. The kitchen device keeps the data'),
      ],
    );
  }
}
