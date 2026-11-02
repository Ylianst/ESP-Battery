import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:battery_dashboard/battery_connection.dart';
import 'package:battery_dashboard/main.dart';
import 'package:battery_dashboard/protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';

void main() {
  testWidgets(
    'connect controls drive a real read-only TCP session and display telemetry',
    (tester) async {
      final connection = BatteryConnection();
      ServerSocket? server;
      Socket? peer;
      StreamSubscription<Socket>? listener;
      final telemetry = Completer<void>();
      var receivedFromApp = 0;
      connection.addListener(() {
        if (connection.batteries[2]?.measurements != null &&
            !telemetry.isCompleted) {
          telemetry.complete();
        }
      });
      addTearDown(() async {
        connection.dispose();
        peer?.destroy();
        await listener?.cancel();
        await server?.close();
      });
      await tester.runAsync(() async {
        server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        listener = server!.listen((socket) {
          peer = socket;
          socket.listen((data) => receivedFromApp += data.length);
          socket.add(makeFrame(0x42, payload: '02').codeUnits);
          socket.add(
            makeFrame(0, payload: hexBytes(measurementPayload())).codeUnits,
          );
        });
      });
      await tester.binding.setSurfaceSize(const Size(1440, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(BatteryDashboard(connection: connection));
      await tester.enterText(find.byType(TextFormField).first, '127.0.0.1');
      await tester.enterText(
        find.byType(TextFormField).last,
        '${server!.port}',
      );
      await tester.tap(find.text('Connect'));
      for (var i = 0; i < 250 && !telemetry.isCompleted; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(telemetry.isCompleted, isTrue, reason: connection.message);
      await tester.pumpAndSettle();
      expect(find.text('Battery 2'), findsOneWidget);
      expect(find.text('CELL 16'), findsOneWidget);
      expect(find.text('Sensor 6'), findsOneWidget);
      expect(find.text('CONNECTED'), findsOneWidget);
      expect(receivedFromApp, 0);
      await tester.tap(find.text('Disconnect'));
      await tester.pumpAndSettle();
      expect(find.text('STALE'), findsOneWidget);
      expect(find.text('OFFLINE'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('empty dashboard validates host and port before connecting', (
    tester,
  ) async {
    final connection = BatteryConnection();
    addTearDown(connection.dispose);
    await tester.binding.setSurfaceSize(const Size(1000, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(BatteryDashboard(connection: connection));
    expect(find.text('Your batteries, at a glance'), findsOneWidget);
    expect(find.text('sunpower.local'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField).first, '');
    await tester.enterText(find.byType(TextFormField).last, '0');
    await tester.tap(find.text('Connect'));
    await tester.pump();
    expect(
      find.text('Enter a hostname or IP (no URL or port)'),
      findsOneWidget,
    );
    expect(find.text('Use 1 - 65535'), findsOneWidget);
    expect(connection.state, LinkState.disconnected);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'renders cells, temperatures, warnings and details at narrow and desktop sizes',
    (tester) async {
      const previewFont = String.fromEnvironment('DASHBOARD_FONT');
      if (previewFont.isNotEmpty) {
        await tester.runAsync(() async {
          final font = FontLoader('Roboto')
            ..addFont(
              File(previewFont).readAsBytes().then(ByteData.sublistView),
            );
          await font.load();
          await (FontLoader('MaterialIcons')
                ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
              .load();
        });
      }
      final connection = BatteryConnection()..state = LinkState.connected;
      addTearDown(connection.dispose);
      final now = DateTime.now();
      for (final address in [2, 3, 4]) {
        connection.batteries[address] = sampleBattery(
          address,
          now,
          warning: address == 3,
        );
      }
      connection.validFrames = 1024;
      connection.message = 'Listening for battery replies';
      addTearDown(() => tester.binding.setSurfaceSize(null));
      for (final width in [360.0, 600.0, 900.0, 1440.0]) {
        await tester.binding.setSurfaceSize(Size(width, 1200));
        await tester.pumpWidget(
          RepaintBoundary(
            key: const Key('preview'),
            child: BatteryDashboard(connection: connection),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Battery 2'), findsOneWidget);
        expect(find.text('Battery 3'), findsOneWidget);
        expect(find.text('CELL 16'), findsNWidgets(3));
        expect(find.text('Sensor 6'), findsNWidgets(3));
        expect(find.text('3 nonzero warning fields'), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'Viewport $width');
      }
      const screenshot = String.fromEnvironment('DASHBOARD_SCREENSHOT');
      if (screenshot.isNotEmpty) {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const Key('preview')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(screenshot);
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      final details = find.text('Protocol details & vendor fields').first;
      await tester.ensureVisible(details);
      await tester.tap(details);
      await tester.pumpAndSettle();
      expect(
        find.text('Measurement extension: 2710430000000064'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('disconnected measurements are visibly stale, never live', (
    tester,
  ) async {
    final connection = BatteryConnection();
    addTearDown(connection.dispose);
    connection.batteries[2] = sampleBattery(2, DateTime.now());
    await tester.binding.setSurfaceSize(const Size(1000, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(BatteryDashboard(connection: connection));
    await tester.pumpAndSettle();
    expect(find.text('STALE'), findsOneWidget);
    expect(find.text('LIVE'), findsNothing);
    expect(find.textContaining('Warning data stale'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
