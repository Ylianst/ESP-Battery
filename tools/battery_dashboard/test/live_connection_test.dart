import 'package:battery_dashboard/battery_connection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const host = String.fromEnvironment('LIVE_HOST');
  const port = int.fromEnvironment('LIVE_PORT', defaultValue: 1234);
  test(
    'live ESP32 bridge yields validated measurements and warning data',
    () async {
      final connection = BatteryConnection();
      addTearDown(connection.dispose);
      await connection.connect(host, port);
      expect(connection.connected, isTrue, reason: connection.message);
      final deadline = DateTime.now().add(const Duration(seconds: 25));
      while (!connection.batteries.values.any(
        (battery) => battery.measurements != null && battery.warnings != null,
      )) {
        if (!connection.connected || DateTime.now().isAfter(deadline)) {
          fail(
            'No complete telemetry/status pair: ${connection.message}; '
            '${connection.traffic.take(5).map((e) => e.message).join('\n')}',
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      for (final battery in connection.batteries.values.where(
        (b) => b.measurements != null,
      )) {
        final data = battery.measurements!;
        expect(data.cells, isNotEmpty);
        expect(data.temperatures, isNotEmpty);
        expect(data.voltage, closeTo(data.cells.reduce((a, b) => a + b), 0.2));
        expect(data.voltage, inInclusiveRange(40, 60));
        expect(data.fullAh, greaterThan(0));
        // ignore: avoid_print
        print(
          'Battery ${battery.address}: ${data.voltage.toStringAsFixed(3)} V, '
          '${data.cells.length} cells, ${data.temperatures.length} temperatures, '
          '${data.current.toStringAsFixed(2)} A, SOC ${data.soc?.toStringAsFixed(1)}%',
        );
      }
      connection.disconnect();
      expect(connection.connected, isFalse);
    },
    skip: host.isEmpty
        ? 'Set --dart-define=LIVE_HOST to opt into a real TCP connection'
        : false,
  );
}
