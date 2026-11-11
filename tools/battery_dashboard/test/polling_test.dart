import 'package:battery_dashboard/polling.dart';
import 'package:battery_dashboard/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';

void main() {
  final now = DateTime(2026);
  ModbusProtocol decoder() =>
      ModbusProtocol(responseTimeout: const Duration(seconds: 2));
  final basic = bytesFromHex(modbusBasic);
  final status = bytesFromHex(modbusStatus);
  final cells = bytesFromHex(modbusCells);

  test('builds exact read-only ASCII and Modbus frames', () {
    expect(modbusCrc('123456789'.codeUnits), 0x4b37);
    expect(hexBytes(PollRequest.modbus(1, 0, 8).bytes), '010300000008440C');
    expect(
      String.fromCharCodes(PollRequest.pace(2, 0x42).bytes),
      '~25024642E00202FD2E\r',
    );
    expect(
      String.fromCharCodes(PollRequest.pace(2, 0x44).bytes),
      '~25024644E00202FD2C\r',
    );
    final settings = PollingSettings(
      protocol: PollingProtocol.modbus,
      addresses: [1, 4],
    );
    expect(settings.requests.map((r) => r.address), [1, 1, 1, 4, 4, 4]);
    expect(settings.requests.map((r) => r.registerStart), [0, 9, 15, 0, 9, 15]);
    expect(settings.requests.every((r) => r.command == 3), isTrue);
    expect(
      PollingSettings(
        protocol: PollingProtocol.pace,
        addresses: [0, 15],
      ).requests.map((r) => r.address),
      [0, 0, 15, 15],
    );
  });

  test(
    'validates addresses, timing and register ranges without broadcast scans',
    () {
      expect(
        PollingSettings.parseAddresses(' 1, 2,4 ', PollingProtocol.modbus),
        [1, 2, 4],
      );
      for (final text in ['', '1,', '1,1', '0', '248', '-1', 'FF', '1.5']) {
        expect(
          () => PollingSettings.parseAddresses(text, PollingProtocol.modbus),
          throwsFormatException,
          reason: text,
        );
      }
      expect(
        () => PollingSettings.parseAddresses('16', PollingProtocol.pace),
        throwsFormatException,
      );
      expect(() => PollRequest.modbus(0, 0, 8), throwsArgumentError);
      expect(() => PollRequest.modbus(1, 65535, 2), throwsArgumentError);
      expect(() => PollRequest.modbus(1, 0, 126), throwsArgumentError);
      expect(() => PollRequest.pace(2, 0x46), throwsArgumentError);
      expect(
        () => PollingSettings(
          protocol: PollingProtocol.pace,
          addresses: [1],
          requestDelay: Duration.zero,
        ),
        throwsArgumentError,
      );
      expect(
        () => PollingSettings(
          protocol: PollingProtocol.pace,
          addresses: [1],
          responseTimeout: const Duration(minutes: 2),
        ),
        throwsArgumentError,
      );
      final addresses = [1];
      final settings = PollingSettings(
        protocol: PollingProtocol.modbus,
        addresses: addresses,
      );
      addresses.add(2);
      expect(settings.addresses, [1]);
      expect(() => settings.addresses.add(3), throwsUnsupportedError);
    },
  );

  test(
    'captured Modbus frames produce complete correctly scaled telemetry',
    () {
      final protocol = decoder();
      protocol.expect(PollRequest.modbus(1, 0, 8), now);
      expect(protocol.add(basic, at: now).single.measurements, isNull);
      protocol.expect(PollRequest.modbus(1, 9, 4), now);
      final warning = protocol.add(status, at: now).single.warnings!;
      expect(warning.source, MeasurementSource.modbus);
      expect(warning.registers['Status/fault'], 0x0c00);
      expect(warning.nonzeroWarnings, 0);
      expect(warning.cells, isEmpty);
      expect(warning.temperatures, isEmpty);
      protocol.expect(PollRequest.modbus(1, 15, 22), now);
      final data = protocol.add(cells, at: now).single.measurements!;
      expect(data.source, MeasurementSource.modbus);
      expect(data.voltage, 53.47);
      expect(data.current, 0);
      expect(data.soc, 72);
      expect(data.reportedSoh, 100);
      expect(data.remainingAh, 71.15);
      expect(data.fullAh, 100);
      expect(data.designAh, 100);
      expect(data.cycles, 1);
      expect(data.spreadMv, closeTo(26, 0.0001));
      expect(data.temperatures, [17.7, 17.5, 17.6, 17.5, 19.8, 18.4]);
      expect(data.flag, isNull);
      expect(data.extraMarker, isNull);
    },
  );

  test(
    'reassembles every split boundary and suppresses fragmented request echoes',
    () {
      final request = PollRequest.modbus(1, 0, 8);
      for (var split = 1; split < basic.length; split++) {
        final protocol = decoder()..expect(request, now);
        expect(protocol.add(basic.sublist(0, split), at: now), isEmpty);
        final event = protocol.add(basic.sublist(split), at: now).single;
        expect(request.matches(event), isTrue);
      }
      for (var split = 1; split < request.bytes.length; split++) {
        final protocol = decoder()..expect(request, now);
        expect(protocol.add(request.bytes.sublist(0, split), at: now), isEmpty);
        final events = protocol.add([
          ...request.bytes.sublist(split),
          ...basic,
        ], at: now);
        expect(events.first.description, contains('echo'));
        expect(events.where(request.matches), hasLength(1));
      }
    },
  );

  test(
    'CRC, noise, wrong slave and wrong length cannot consume a pending read',
    () {
      final request = PollRequest.modbus(1, 0, 8);
      final protocol = decoder()..expect(request, now);
      final corrupt = [...basic]..[5] ^= 1;
      expect(
        protocol.add([0xff, ...corrupt], at: now).any((e) => e.issue != null),
        isTrue,
      );
      final wrongSlave = modbusFrame([2, 3, 16, ...basic.sublist(3, 19)]);
      final wrongLength = modbusFrame([1, 3, 2, 0, 0]);
      for (final frame in [wrongSlave, wrongLength]) {
        final events = protocol.add(frame, at: now);
        expect(events.any(request.matches), isFalse);
        expect(events.any((e) => e.issue != null), isTrue);
      }
      expect(protocol.add(basic, at: now).where(request.matches), hasLength(1));
      expect(protocol.add(basic, at: now).single.issue, contains('Unexpected'));
    },
  );

  test(
    'exceptions advance safely; expired and incomplete replies stay explicit',
    () {
      final request = PollRequest.modbus(1, 0, 8);
      final protocol = decoder()..expect(request, now);
      final error = protocol.add(modbusFrame([1, 0x83, 2]), at: now).single;
      expect(request.matches(error), isTrue);
      expect(error.issue, contains('Illegal data address'));
      protocol.expect(request, now);
      expect(
        protocol
            .add(basic, at: now.add(const Duration(seconds: 3)))
            .single
            .issue,
        contains('expired'),
      );
      protocol.expect(request, now);
      protocol.add(basic.sublist(0, 6), at: now);
      expect(protocol.finish()!.issue, contains('Incomplete'));
      expect(protocol.finish(), isNull);
    },
  );

  test('missing basic blocks never combine with a previous sweep', () {
    final protocol = decoder();
    protocol.expect(PollRequest.modbus(1, 0, 8), now);
    protocol.add(basic, at: now);
    protocol.expect(PollRequest.modbus(1, 0, 8), now);
    protocol.expect(PollRequest.modbus(1, 15, 22), now);
    final event = protocol.add(cells, at: now).single;
    expect(event.measurements, isNull);
    expect(event.issue, contains('no basic measurements'));
    protocol.expect(PollRequest.modbus(1, 0, 1), now);
    expect(
      protocol.add(modbusFrame([1, 3, 2, 0, 0]), at: now).single.issue,
      contains('Unsupported'),
    );
  });

  test('current and temperatures preserve negative values', () {
    final protocol = decoder();
    final negativeBasic = [...basic.sublist(0, basic.length - 2)]
      ..[3] = 0xff
      ..[4] = 0x9c;
    final negativeCells = [...cells.sublist(0, cells.length - 2)]
      ..[35] = 0xff
      ..[36] = 0x9c;
    protocol.expect(PollRequest.modbus(1, 0, 8), now);
    protocol.add(modbusFrame(negativeBasic), at: now);
    protocol.expect(PollRequest.modbus(1, 15, 22), now);
    final data = protocol
        .add(modbusFrame(negativeCells), at: now)
        .single
        .measurements!;
    expect(data.current, -1);
    expect(data.temperatures.first, -10);
  });
}
