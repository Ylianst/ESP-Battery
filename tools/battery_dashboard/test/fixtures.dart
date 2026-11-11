import 'dart:typed_data';

import 'package:battery_dashboard/battery_connection.dart';
import 'package:battery_dashboard/protocol.dart';
import 'package:battery_dashboard/polling.dart';

const modbusBasic = '010310000014e3004800641bcb271027100001595a';
const modbusStatus = '010308000000000c0000009687';
const modbusCells =
    '01032c0d160d130d110d0f0d0c0d100d100d120d0e0d130d130cfc0d0f0cff0d100d1200b100af00b000af00c600b8ac1a';

Uint8List bytesFromHex(String text) => Uint8List.fromList([
  for (var i = 0; i < text.length; i += 2)
    int.parse(text.substring(i, i + 2), radix: 16),
]);

Uint8List modbusFrame(List<int> body) {
  final crc = modbusCrc(body);
  return Uint8List.fromList([...body, crc & 255, crc >> 8]);
}

String makeFrame(
  int code, {
  String payload = '',
  int address = 2,
  int version = 0x25,
  int type = 0x46,
}) {
  final size = payload.length;
  final check = -(size + (size >> 4) + (size >> 8)) & 15;
  final length = ((check << 12) | size)
      .toRadixString(16)
      .padLeft(4, '0')
      .toUpperCase();
  final body =
      '${hexByte(version)}${hexByte(address)}${hexByte(type)}${hexByte(code)}$length$payload';
  final sum = body.codeUnits.fold(0, (a, b) => a + b);
  return '~$body${(-sum & 0xffff).toRadixString(16).padLeft(4, '0').toUpperCase()}\r';
}

Uint8List measurementPayload({
  int address = 2,
  int current = 221,
  int full = 10000,
}) {
  final values = [
    3350,
    3351,
    3350,
    3351,
    3353,
    3350,
    3350,
    3341,
    3352,
    3354,
    3351,
    3352,
    3350,
    3343,
    3349,
    3352,
  ];
  final temperatures = [2886, 2886, 2880, 2882, 2904, 2896];
  final data = BytesBuilder();
  void word(int value) => data.add([(value >> 8) & 255, value & 255]);
  data.add([0, address, values.length]);
  for (final value in values) {
    word(value);
  }
  data.add([temperatures.length]);
  for (final value in temperatures) {
    word(value);
  }
  word(current);
  word(53599);
  word(6681);
  data.add([2]);
  word(full);
  word(1);
  data.add([0x27, 0x10, 0x43, 0, 0, 0, 0, 0x64]);
  return data.takeBytes();
}

Uint8List warningPayload({int address = 2, bool warning = false}) {
  final data = Uint8List(38);
  data[1] = address;
  data[2] = 16;
  data[19] = 6;
  data[31] = 0x26;
  if (warning) {
    data[3] = 1;
    data[20] = 2;
    data[26] = 1;
  }
  return data;
}

BatteryState sampleBattery(int address, DateTime now, {bool warning = false}) {
  final battery = BatteryState(address)
    ..measurements = Measurements.parse(
      measurementPayload(address: address),
      address,
    )
    ..warnings = BatteryWarnings.parse(
      warningPayload(address: address, warning: warning),
      address,
    )
    ..measurementAt = now
    ..warningsAt = now
    ..lastSeen = now
    ..packNumber = address
    ..lastFrame = makeFrame(
      0,
      payload: hexBytes(measurementPayload(address: address)),
      address: address,
    ).trim();
  battery.history.addAll(
    List.generate(
      30,
      (i) => VoltageSample(
        now.subtract(Duration(seconds: (29 - i) * 10)),
        53.55 + i * 0.0015 + (i % 3) * 0.003,
      ),
    ),
  );
  return battery;
}
