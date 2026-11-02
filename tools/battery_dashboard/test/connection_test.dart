import 'dart:async';
import 'dart:io';

import 'package:battery_dashboard/battery_connection.dart';
import 'package:battery_dashboard/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';

Future<void> waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for connection state');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  test('read-only socket discovers replies, not scanned addresses; retains stale data on disconnect', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final peerReady = Completer<Socket>();
    var sentByClient = 0;
    final listener = server.listen((socket) {
      peerReady.complete(socket);
      socket.listen((data) => sentByClient += data.length);
    });
    final connection = BatteryConnection();
    addTearDown(() async {
      connection.dispose();
      if (peerReady.isCompleted) (await peerReady.future).destroy();
      await listener.cancel();
      await server.close();
    });
    await connection.connect('127.0.0.1', server.port);
    expect(connection.connected, isTrue);
    final peer = await peerReady.future;
    for (var address = 2; address < 64; address++) {
      peer.add(makeFrame(0x90, address: address).codeUnits);
    }
    await peer.flush();
    await waitFor(() => connection.validFrames == 62);
    expect(connection.batteries, isEmpty);
    peer.add(makeFrame(0x42, payload: '02').codeUnits);
    final response = makeFrame(0, payload: hexBytes(measurementPayload()));
    peer.add(response.substring(0, 15).codeUnits);
    await peer.flush();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(connection.batteries, isEmpty);
    peer.add(response.substring(15).codeUnits);
    peer.add(makeFrame(0x44, payload: '02').codeUnits);
    peer.add(makeFrame(0, payload: hexBytes(warningPayload())).codeUnits);
    await peer.flush();
    await waitFor(() => connection.batteries[2]?.warnings != null);
    expect(connection.batteries.keys, [2]);
    expect(connection.batteries[2]!.measurements!.voltage, 53.599);
    expect(connection.batteries[2]!.fresh(DateTime.now(), true), isTrue);
    expect(sentByClient, 0);
    connection.disconnect();
    expect(connection.state, LinkState.disconnected);
    expect(connection.batteries[2]!.fresh(DateTime.now(), false), isFalse);
    expect(connection.batteries[2]!.measurements, isNotNull);
  });

  test(
    'reports remote disconnect and corrupt data, bounds history and traffic',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final ready = Completer<Socket>();
      final listener = server.listen(ready.complete);
      final connection = BatteryConnection();
      addTearDown(() async {
        connection.dispose();
        if (ready.isCompleted) (await ready.future).destroy();
        await listener.cancel();
        await server.close();
      });
      await connection.connect('127.0.0.1', server.port);
      final peer = await ready.future;
      peer.add('~250246900000FDA5\r'.codeUnits);
      for (var i = 0; i < 125; i++) {
        peer.add(makeFrame(0x42, payload: '02').codeUnits);
        peer.add(
          makeFrame(0, payload: hexBytes(measurementPayload())).codeUnits,
        );
      }
      await peer.flush();
      await waitFor(() => connection.validFrames == 250);
      expect(connection.issues, 1);
      expect(connection.batteries[2]!.history.length, 120);
      expect(connection.traffic.length, 80);
      await peer.close();
      await waitFor(() => !connection.connected);
      expect(connection.message, contains('closed the connection'));
      expect(connection.batteries[2]!.measurements, isNotNull);
    },
  );

  test(
    'failed connection and invalid input produce explicit visible errors',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      await server.close();
      final connection = BatteryConnection();
      addTearDown(connection.dispose);
      await connection.connect('127.0.0.1', port);
      expect(connection.state, LinkState.disconnected);
      expect(connection.message, contains('Cannot connect'));
      expect(connection.traffic.first.issue, isTrue);
      await connection.connect('', 0);
      expect(connection.message, contains('Enter a hostname'));
    },
  );

  test('cancelled connect cannot replace a newer disconnected state', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final peers = <Socket>[];
    final listener = server.listen(peers.add);
    final connection = BatteryConnection();
    addTearDown(() async {
      connection.dispose();
      for (final peer in peers) {
        peer.destroy();
      }
      await listener.cancel();
      await server.close();
    });
    final pending = connection.connect('127.0.0.1', server.port);
    connection.disconnect();
    await pending;
    expect(connection.state, LinkState.disconnected);
    expect(connection.message, startsWith('Disconnected'));
    expect(connection.batteries, isEmpty);
  });

  test('freshness depends on measurement time, not other bus traffic', () {
    final now = DateTime.now();
    final battery = sampleBattery(2, now.subtract(const Duration(seconds: 31)));
    battery.lastSeen = now;
    expect(battery.fresh(now, true), isFalse);
    expect(battery.warningsFresh(now, true), isFalse);
    battery.measurementAt = now;
    expect(battery.fresh(now, true), isTrue);
    expect(battery.warningsFresh(now, true), isFalse);
    expect(battery.fresh(now, false), isFalse);
  });
}
