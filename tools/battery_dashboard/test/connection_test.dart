import 'dart:async';
import 'dart:io';

import 'package:battery_dashboard/battery_connection.dart';
import 'package:battery_dashboard/protocol.dart';
import 'package:battery_dashboard/polling.dart';
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
  test('active ASCII polls only selected packs sequentially and stops on disconnect', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final peers = <Socket>[];
    final requests = <List<int>>[];
    final listener = server.listen((socket) {
      peers.add(socket);
      var buffer = '';
      socket.listen((data) {
        buffer += String.fromCharCodes(data);
        while (buffer.contains('\r')) {
          final end = buffer.indexOf('\r');
          final frame = buffer.substring(0, end + 1);
          buffer = buffer.substring(end + 1);
          final address = int.parse(frame.substring(3, 5), radix: 16);
          final command = int.parse(frame.substring(7, 9), radix: 16);
          requests.add([address, command]);
          final payload = command == 0x42
              ? measurementPayload(address: address)
              : warningPayload(address: address).sublist(0, 34);
          socket.add(
            makeFrame(
              0,
              address: address,
              version: 0x20,
              payload: hexBytes(payload),
            ).codeUnits,
          );
        }
      });
    });
    final connection = BatteryConnection();
    addTearDown(() async {
      connection.dispose();
      for (final peer in peers) {
        peer.destroy();
      }
      await listener.cancel();
      await server.close();
    });
    await connection.connect(
      '127.0.0.1',
      server.port,
      polling: PollingSettings(
        protocol: PollingProtocol.pace,
        addresses: [2, 4],
        requestDelay: const Duration(milliseconds: 5),
      ),
    );
    await waitFor(
      () => connection.batteries[4]?.warnings != null && requests.length >= 5,
    );
    expect(requests.take(5), [
      [2, 0x42],
      [2, 0x44],
      [4, 0x42],
      [4, 0x44],
      [2, 0x42],
    ]);
    expect(connection.batteries.keys, [2, 4]);
    expect(
      connection.batteries.values.every((b) => b.measurements != null),
      isTrue,
    );
    expect(connection.issues, 0);
    expect(
      connection.traffic.any((entry) => entry.message.startsWith('TX ')),
      isTrue,
    );
    connection.disconnect();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final count = requests.length;
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(requests.length, count);
    await connection.connect('127.0.0.1', server.port);
    await waitFor(() => peers.length == 2);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(requests.length, count);
    expect(connection.polling, isNull);
    expect(connection.batteries, isEmpty);
    expect(connection.receivedBytes, 0);
  });

  test(
    'active Modbus cycles selected slaves and publishes complete snapshots',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final peers = <Socket>[];
      final requests = <List<int>>[];
      final listener = server.listen((socket) {
        peers.add(socket);
        var buffer = <int>[];
        socket.listen((data) {
          buffer.addAll(data);
          while (buffer.length >= 8) {
            final frame = buffer.sublist(0, 8);
            buffer = buffer.sublist(8);
            final start = frame[2] * 256 + frame[3];
            requests.add([frame[0], start]);
            final captured = bytesFromHex(switch (start) {
              0 => modbusBasic,
              9 => modbusStatus,
              _ => modbusCells,
            });
            final body = captured.sublist(0, captured.length - 2)
              ..[0] = frame[0];
            socket.add(modbusFrame(body));
          }
        });
      });
      final connection = BatteryConnection();
      addTearDown(() async {
        connection.dispose();
        for (final peer in peers) {
          peer.destroy();
        }
        await listener.cancel();
        await server.close();
      });
      await connection.connect(
        '127.0.0.1',
        server.port,
        polling: PollingSettings(
          protocol: PollingProtocol.modbus,
          addresses: [1, 4],
          requestDelay: const Duration(milliseconds: 5),
        ),
      );
      await waitFor(
        () =>
            connection.batteries[4]?.measurements != null &&
            requests.length >= 7,
      );
      expect(requests.take(7), [
        [1, 0],
        [1, 9],
        [1, 15],
        [4, 0],
        [4, 9],
        [4, 15],
        [1, 0],
      ]);
      expect(connection.batteries.keys, [1, 4]);
      expect(connection.batteries[1]!.measurements!.soc, 72);
      expect(connection.batteries[4]!.measurements!.pack, 4);
      expect(connection.batteries[4]!.warnings!.nonzeroWarnings, 0);
      expect(connection.issues, 0);
      connection.disconnect();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final count = requests.length;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(requests.length, count);
    },
  );

  test('wrong Modbus byte count waits for timeout; exceptions do not stall later slaves', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final peers = <Socket>[];
    final receivedAt = <DateTime>[];
    final listener = server.listen((socket) {
      peers.add(socket);
      var buffer = <int>[];
      socket.listen((data) {
        buffer.addAll(data);
        while (buffer.length >= 8) {
          final frame = buffer.sublist(0, 8);
          buffer = buffer.sublist(8);
          receivedAt.add(DateTime.now());
          final address = frame[0];
          final start = frame[2] * 256 + frame[3];
          if (address == 1 && start == 0) {
            socket.add(modbusFrame([1, 3, 2, 0, 0]));
          } else if (address == 1 && start == 9) {
            socket.add(modbusFrame([1, 0x83, 2]));
          } else {
            final captured = bytesFromHex(switch (start) {
              0 => modbusBasic,
              9 => modbusStatus,
              _ => modbusCells,
            });
            final body = captured.sublist(0, captured.length - 2)
              ..[0] = address;
            socket.add(modbusFrame(body));
          }
        }
      });
    });
    final connection = BatteryConnection();
    addTearDown(() async {
      connection.dispose();
      for (final peer in peers) {
        peer.destroy();
      }
      await listener.cancel();
      await server.close();
    });
    await connection.connect(
      '127.0.0.1',
      server.port,
      polling: PollingSettings(
        protocol: PollingProtocol.modbus,
        addresses: [1, 2],
        responseTimeout: const Duration(milliseconds: 80),
        requestDelay: const Duration(milliseconds: 5),
      ),
    );
    await waitFor(() => connection.batteries[2]?.measurements != null);
    expect(
      receivedAt[1].difference(receivedAt[0]).inMilliseconds,
      greaterThanOrEqualTo(60),
    );
    expect(connection.batteries[1]!.measurements, isNull);
    expect(
      connection.traffic.any(
        (entry) => entry.message.contains('no reply within'),
      ),
      isTrue,
    );
    expect(
      connection.traffic.any(
        (entry) => entry.message.contains('Illegal data address'),
      ),
      isTrue,
    );
    expect(
      connection.traffic.any(
        (entry) => entry.message.contains('no basic measurements'),
      ),
      isTrue,
    );
    connection.disconnect();
  });

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
