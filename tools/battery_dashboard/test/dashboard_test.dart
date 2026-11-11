import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:battery_dashboard/battery_connection.dart';
import 'package:battery_dashboard/main.dart';
import 'package:battery_dashboard/protocol.dart';
import 'package:battery_dashboard/polling.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';

class CapturingConnection extends BatteryConnection {
  PollingSettings? captured;

  @override
  Future<void> connect(
    String host,
    int port, {
    PollingSettings? polling,
  }) async {
    captured = polling;
    showState(LinkState.connecting);
  }

  void showState(LinkState value) {
    state = value;
    notifyListeners();
  }
}

void main() {
  testWidgets(
    'polling is opt-in, responsive, validated and locked until disconnect',
    (tester) async {
      final connection = CapturingConnection();
      addTearDown(connection.dispose);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.binding.setSurfaceSize(const Size(1000, 1200));
      await tester.pumpWidget(BatteryDashboard(connection: connection));
      expect(
        tester
            .widget<SwitchListTile>(find.byKey(const Key('enable-polling')))
            .value,
        isFalse,
      );
      expect(find.byType(TextFormField), findsNWidgets(2));
      await tester.tap(find.byKey(const Key('enable-polling')));
      await tester.pumpAndSettle();
      for (final width in [360.0, 600.0, 900.0, 1440.0]) {
        await tester.binding.setSurfaceSize(Size(width, 1200));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('polling-addresses')), findsOneWidget);
        expect(
          tester.takeException(),
          isNull,
          reason: 'Active controls at $width',
        );
      }
      await tester.enterText(find.byKey(const Key('polling-addresses')), '0');
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();
      expect(find.text('Use unique addresses 1-247'), findsOneWidget);
      expect(connection.state, LinkState.disconnected);
      await tester.tap(find.byKey(const Key('polling-protocol')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ASCII PACE (25 / 20 replies)').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('polling-addresses')), '16');
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();
      expect(find.text('Use unique addresses 0-15'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('polling-addresses')), '1,3');
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();
      expect(connection.captured!.addresses, [1, 3]);
      expect(connection.captured!.protocol, PollingProtocol.pace);
      for (final state in [LinkState.connecting, LinkState.connected]) {
        connection.showState(state);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<SwitchListTile>(find.byKey(const Key('enable-polling')))
              .onChanged,
          isNull,
        );
        expect(
          tester
              .widget<TextFormField>(find.byKey(const Key('polling-addresses')))
              .enabled,
          isFalse,
        );
        expect(
          tester
              .widget<DropdownButtonFormField<PollingProtocol>>(
                find.byKey(const Key('polling-protocol')),
              )
              .onChanged,
          isNull,
        );
      }
      await tester.tap(find.text('Disconnect'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('polling-addresses')))
            .enabled,
        isTrue,
      );
      await tester.tap(find.byKey(const Key('enable-polling')));
      await tester.pumpAndSettle();
      expect(find.byType(TextFormField), findsNWidgets(2));
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();
      expect(connection.captured, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Modbus telemetry uses reported SOC and no fabricated PACE metadata',
    (tester) async {
      final now = DateTime.now();
      final protocol = ModbusProtocol(
        responseTimeout: const Duration(seconds: 2),
      );
      protocol.expect(PollRequest.modbus(1, 0, 8), now);
      protocol.add(bytesFromHex(modbusBasic), at: now);
      protocol.expect(PollRequest.modbus(1, 9, 4), now);
      final warnings = protocol
          .add(bytesFromHex(modbusStatus), at: now)
          .single
          .warnings!;
      protocol.expect(PollRequest.modbus(1, 15, 22), now);
      final measurements = protocol
          .add(bytesFromHex(modbusCells), at: now)
          .single
          .measurements!;
      final connection = BatteryConnection()..state = LinkState.connected;
      connection.batteries[1] = BatteryState(1)
        ..measurements = measurements
        ..warnings = warnings
        ..measurementAt = now
        ..warningsAt = now
        ..lastFrame = modbusCells.toUpperCase();
      addTearDown(connection.dispose);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.binding.setSurfaceSize(const Size(1000, 1200));
      await tester.pumpWidget(BatteryDashboard(connection: connection));
      await tester.pumpAndSettle();
      expect(find.text('REPORTED SOC'), findsOneWidget);
      expect(find.text('CALC. SOC'), findsNothing);
      expect(find.text('MOSFET'), findsOneWidget);
      expect(find.text('Environment'), findsOneWidget);
      final details = find.text('Protocol details & vendor fields');
      await tester.ensureVisible(details);
      await tester.tap(details);
      await tester.pumpAndSettle();
      expect(find.textContaining('Modbus RTU / function 03'), findsOneWidget);
      expect(find.textContaining('Reported SOH: 100%'), findsOneWidget);
      expect(find.text('Latest validated reply (RTU hex)'), findsOneWidget);
      expect(find.textContaining('Measurement flag'), findsNothing);
      final warningDetails = find.text('Warning fields all zero');
      await tester.ensureVisible(warningDetails);
      await tester.tap(warningDetails);
      await tester.pumpAndSettle();
      expect(find.text('Cell warning codes: not provided'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

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
