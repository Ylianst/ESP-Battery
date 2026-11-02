import 'package:battery_dashboard/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';

void main() {
  final now = DateTime(2026, 1, 1);
  List<ProtocolEvent> feed(
    BatteryProtocol protocol,
    String text, {
    DateTime? at,
  }) => protocol.add(text.codeUnits, at: at ?? now);

  test('validates captured frames and reassembles arbitrary TCP chunks', () {
    final protocol = BatteryProtocol();
    expect(feed(protocol, '~2502'), isEmpty);
    final events = feed(protocol, '46900000FDA4\r\n~250346900000FDA3\r');
    expect(events.length, 2);
    expect(events.map((e) => e.address), [2, 3]);
    expect(
      events.every((e) => e.valid && !e.response && e.command == 0x90),
      isTrue,
    );
    expect(feed(protocol, '~25024642E00202FD2E\r').single.command, 0x42);
    expect(feed(protocol, '~25024644E00202FD2C\r').single.command, 0x44);
  });

  test('rejects invalid checksums, lengths and nonhex data', () {
    final protocol = BatteryProtocol();
    for (final entry in {
      '~250246900000FDA5\r': 'Frame checksum',
      '~25024642F00202FD2E\r': 'Length checksum',
      '~25024642E002FD2E\r': 'Payload length',
      '~25024690ZZZZFDA4\r': 'ASCII-hex',
    }.entries) {
      final event = feed(protocol, entry.key).single;
      expect(event.valid, isFalse);
      expect(event.issue, contains(entry.value));
    }
  });

  test('matches by address and decodes exact SG48100 units and fields', () {
    final protocol = BatteryProtocol();
    feed(protocol, makeFrame(0x42, payload: '02'));
    feed(protocol, makeFrame(0x44, payload: '03', address: 3));
    final event = feed(
      protocol,
      makeFrame(0, payload: hexBytes(measurementPayload())),
    ).single;
    final data = event.measurements!;
    expect(event.issue, isNull);
    expect(event.command, 0x42);
    expect(data.voltage, 53.599);
    expect(data.current, 2.21);
    expect(data.remainingAh, 66.81);
    expect(data.fullAh, 100);
    expect(data.soc, closeTo(66.81, 0.0001));
    expect(data.cycles, 1);
    expect(data.cells.length, 16);
    expect(data.cells.first, 3.350);
    expect(data.spreadMv, closeTo(13, 0.0001));
    expect(data.temperatures, [15.5, 15.5, 14.9, 15.1, 17.3, 16.5]);
    expect(data.extension, '2710430000000064');
    expect(data.cells.reduce((a, b) => a + b), closeTo(data.voltage, 0.05));
  });

  test(
    'signed current and zero full capacity are represented without invalid SOC',
    () {
      final data = Measurements.parse(
        measurementPayload(current: -221, full: 0),
        2,
      );
      expect(data.current, -2.21);
      expect(data.soc, isNull);
    },
  );

  test(
    'warning data distinguishes warning flags from instruction/control bits',
    () {
      final normal = BatteryWarnings.parse(warningPayload(), 2);
      expect(normal.cells.length, 16);
      expect(normal.temperatures.length, 6);
      expect(normal.registers['Instruction'], 0x26);
      expect(normal.nonzeroWarnings, 0);
      final warning = BatteryWarnings.parse(warningPayload(warning: true), 2);
      expect(warning.nonzeroWarnings, 3);
      final protocol = BatteryProtocol();
      feed(protocol, makeFrame(0x44, payload: '02'));
      expect(
        feed(
          protocol,
          makeFrame(0, payload: hexBytes(warningPayload())),
        ).single.warnings,
        isNotNull,
      );
    },
  );

  test('unmatched/expired replies never turn into guessed measurements', () {
    final protocol = BatteryProtocol();
    final reply = makeFrame(0, payload: hexBytes(measurementPayload()));
    expect(feed(protocol, reply).single.measurements, isNull);
    feed(protocol, makeFrame(0x42, payload: '02'));
    final stale = feed(
      protocol,
      reply,
      at: now.add(const Duration(seconds: 6)),
    ).single;
    expect(stale.command, isNull);
    expect(stale.measurements, isNull);
  });

  test(
    'preserves unknown commands, unsupported versions and error replies',
    () {
      final protocol = BatteryProtocol();
      final unknown = feed(protocol, makeFrame(0xee, payload: '1234')).single;
      expect(unknown.description, contains('unknown command'));
      expect(unknown.raw, contains('1234'));
      expect(
        feed(protocol, makeFrame(0x42, version: 0x20)).single.issue,
        contains('Unsupported'),
      );
      expect(
        feed(protocol, makeFrame(0x42, type: 0x47)).single.issue,
        contains('Unsupported'),
      );
      feed(protocol, makeFrame(0x42, payload: '02'));
      final error = feed(protocol, makeFrame(2)).single;
      expect(error.response, isTrue);
      expect(error.issue, contains('returned error'));
      expect(error.measurements, isNull);
    },
  );

  test('reports unsupported and truncated payloads without throwing', () {
    final protocol = BatteryProtocol();
    for (final command in [0x42, 0x44]) {
      for (final payload in ['00', '000210', '000200', '000201000100']) {
        feed(protocol, makeFrame(command, payload: '02'));
        final event = feed(protocol, makeFrame(0, payload: payload)).single;
        expect(event.issue, isNotNull);
        expect(event.measurements, isNull);
        expect(event.warnings, isNull);
      }
    }
  });

  test(
    'decodes one-byte pack field and reports framing loss, noise and shutdown',
    () {
      final protocol = BatteryProtocol();
      feed(protocol, '~250246900000FDA4\r');
      expect(feed(protocol, '~25024600E00202FD34\r').single.packNumber, 2);
      expect(
        feed(protocol, 'noise\x00\r\n').single.issue,
        contains('Unframed'),
      );
      final events = feed(protocol, '~2502~250246900000FDA4\r');
      expect(events.first.issue, contains('incomplete'));
      expect(events.last.valid, isTrue);
      expect(
        feed(
          protocol,
          '~${'0' * 4114}',
        ).any((e) => e.issue!.contains('maximum')),
        isTrue,
      );
      feed(protocol, '~2502');
      expect(protocol.finish()!.issue, contains('Incomplete'));
      expect(protocol.finish(), isNull);
    },
  );
}
