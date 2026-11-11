import 'dart:typed_data';

import 'protocol.dart';

enum PollingProtocol { modbus, pace }

class PollingSettings {
  PollingSettings({
    required this.protocol,
    required List<int> addresses,
    this.responseTimeout = const Duration(seconds: 2),
    this.requestDelay = const Duration(milliseconds: 250),
  }) : addresses = List.unmodifiable(addresses) {
    parseAddresses(addresses.join(','), protocol);
    if (responseTimeout <= Duration.zero ||
        responseTimeout > const Duration(minutes: 1) ||
        requestDelay < const Duration(milliseconds: 5)) {
      throw ArgumentError('Invalid polling timeout or request delay');
    }
  }

  final PollingProtocol protocol;
  final List<int> addresses;
  final Duration responseTimeout;
  final Duration requestDelay;

  static List<int> parseAddresses(String text, PollingProtocol protocol) {
    final minimum = protocol == PollingProtocol.modbus ? 1 : 0;
    final maximum = protocol == PollingProtocol.modbus ? 247 : 15;
    final parts = text.split(',').map((part) => part.trim()).toList();
    if (parts.any((part) => !RegExp(r'^\d+$').hasMatch(part))) {
      throw const FormatException('Enter comma-separated decimal addresses');
    }
    final addresses = parts.map(int.parse).toList();
    if (addresses.any((address) => address < minimum || address > maximum) ||
        addresses.toSet().length != addresses.length) {
      throw FormatException('Use unique addresses $minimum-$maximum');
    }
    return addresses;
  }

  List<PollRequest> get requests => [
    for (final address in addresses)
      if (protocol == PollingProtocol.pace) ...[
        PollRequest.pace(address, 0x42),
        PollRequest.pace(address, 0x44),
      ] else ...[
        PollRequest.modbus(address, 0, 8),
        PollRequest.modbus(address, 9, 4),
        PollRequest.modbus(address, 15, 22),
      ],
  ];
}

class PollRequest {
  PollRequest.pace(this.address, this.command)
    : registerStart = null,
      count = null {
    if (address < 0 || address > 15 || (command != 0x42 && command != 0x44)) {
      throw ArgumentError('Invalid ASCII PACE read request');
    }
    final body =
        '25${hexByte(address)}46${hexByte(command)}E002${hexByte(address)}';
    final sum = body.codeUnits.fold(0, (a, b) => a + b);
    final checksum = (-sum & 0xffff)
        .toRadixString(16)
        .padLeft(4, '0')
        .toUpperCase();
    bytes = Uint8List.fromList('~$body$checksum\r'.codeUnits);
  }

  PollRequest.modbus(this.address, int start, int words)
    : command = 3,
      registerStart = start,
      count = words {
    if (address < 1 ||
        address > 247 ||
        start < 0 ||
        words < 1 ||
        words > 125 ||
        start + words > 65536) {
      throw ArgumentError('Invalid Modbus holding-register read');
    }
    bytes = Uint8List(8);
    final data = ByteData.sublistView(bytes);
    bytes[0] = address;
    bytes[1] = 3;
    data.setUint16(2, start);
    data.setUint16(4, words);
    data.setUint16(6, modbusCrc(bytes.take(6)), Endian.little);
  }

  final int address;
  final int command;
  final int? registerStart;
  final int? count;
  late final Uint8List bytes;

  String get description => registerStart == null
      ? 'Battery $address: ${commandNames[command]}'
      : 'Battery $address: holding $registerStart-${registerStart! + count! - 1}';

  bool matches(ProtocolEvent event) =>
      event.valid &&
      event.response &&
      event.address == address &&
      event.command == command &&
      event.registerStart == registerStart;
}

int modbusCrc(Iterable<int> bytes) {
  var crc = 0xffff;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = crc & 1 != 0 ? (crc >> 1) ^ 0xa001 : crc >> 1;
    }
  }
  return crc;
}

class ModbusProtocol {
  ModbusProtocol({required this.responseTimeout});
  final Duration responseTimeout;
  List<int> _buffer = [];
  PollRequest? _request;
  DateTime? _requestedAt;
  final Map<int, Uint8List> _basic = {};

  ProtocolEvent? expect(PollRequest request, DateTime at) {
    if (request.registerStart == null) {
      throw ArgumentError('Modbus decoding requires a Modbus request');
    }
    final partial = finish();
    _request = request;
    _requestedAt = at;
    if (request.registerStart == 0) _basic.remove(request.address);
    return partial;
  }

  ProtocolEvent? finish() {
    final partial = _buffer.isEmpty
        ? null
        : _issue('Incomplete Modbus RTU data', hexBytes(_buffer));
    _buffer = [];
    _request = null;
    _requestedAt = null;
    return partial;
  }

  List<ProtocolEvent> add(List<int> data, {required DateTime at}) {
    final bytes = [..._buffer, ...data];
    final events = <ProtocolEvent>[];
    var offset = 0;
    var noiseStart = 0;
    int? incomplete;
    void noise(int end) {
      if (end > noiseStart) {
        events.add(
          _issue(
            'Unframed Modbus RTU bytes',
            hexBytes(bytes.sublist(noiseStart, end)),
          ),
        );
      }
    }

    while (offset < bytes.length) {
      final remaining = bytes.length - offset;
      final request = _request;
      if (request != null) {
        final size = remaining < 8 ? remaining : 8;
        var echo = true;
        for (var i = 0; i < size; i++) {
          if (bytes[offset + i] != request.bytes[i]) echo = false;
        }
        if (echo) {
          if (remaining < 8) {
            incomplete ??= offset;
            offset++;
            continue;
          }
          noise(offset);
          events.add(
            ProtocolEvent(
              description: 'Ignored Modbus request echo',
              raw: hexBytes(request.bytes),
            ),
          );
          offset += 8;
          noiseStart = offset;
          incomplete = null;
          continue;
        }
      }
      if (bytes[offset] < 1 || bytes[offset] > 247) {
        offset++;
        continue;
      }
      if (remaining < 2) {
        incomplete ??= offset;
        break;
      }
      final fn = bytes[offset + 1];
      if (fn != 3 && fn != 0x83) {
        offset++;
        continue;
      }
      if (remaining < 3) {
        incomplete ??= offset;
        break;
      }
      final count = bytes[offset + 2];
      if (fn == 3 && (count < 2 || count > 250 || count.isOdd)) {
        offset++;
        continue;
      }
      final length = fn == 0x83 ? 5 : count + 5;
      if (remaining < length) {
        incomplete ??= offset;
        offset++;
        continue;
      }
      final frame = Uint8List.fromList(bytes.sublist(offset, offset + length));
      final crc = ByteData.sublistView(frame)
          .getUint16(length - 2, Endian.little);
      if (crc != modbusCrc(frame.take(length - 2))) {
        if (incomplete == null) {
          events.add(_issue('Modbus CRC mismatch', hexBytes(frame)));
        }
        offset++;
        continue;
      }
      noise(offset);
      events.add(_decode(frame, at));
      offset += length;
      noiseStart = offset;
      incomplete = null;
    }
    final keepFrom = incomplete ?? bytes.length;
    noise(keepFrom);
    _buffer = bytes.sublist(keepFrom);
    return events;
  }

  ProtocolEvent _issue(String text, String raw) =>
      ProtocolEvent(description: text, raw: raw, issue: text);

  ProtocolEvent _decode(Uint8List frame, DateTime at) {
    final request = _request;
    final requestedAt = _requestedAt;
    final raw = hexBytes(frame);
    if (request == null ||
        requestedAt == null ||
        request.address != frame[0] ||
        at.isBefore(requestedAt) ||
        at.difference(requestedAt) > responseTimeout) {
      return ProtocolEvent(
        description: 'Unexpected/expired Modbus reply',
        raw: raw,
        valid: true,
        issue: 'Unexpected/expired Modbus reply from ${frame[0]}',
      );
    }
    final exception = frame[1] == 0x83;
    if (!exception && frame[2] != request.count! * 2) {
      return ProtocolEvent(
        description: 'Wrong Modbus byte count',
        raw: raw,
        valid: true,
        issue:
            '${request.description}: expected ${request.count! * 2} data bytes, got ${frame[2]}',
      );
    }
    _request = null;
    _requestedAt = null;
    Measurements? measurements;
    BatteryWarnings? warnings;
    String? issue;
    var description = '${request.description}: response; CRC OK';
    if (exception) {
      const names = {
        1: 'Illegal function',
        2: 'Illegal data address',
        3: 'Illegal data value',
        4: 'Slave device failure',
        6: 'Slave device busy',
      };
      issue =
          '${request.description}: Modbus exception 0x${hexByte(frame[2])} '
          '(${names[frame[2]] ?? 'Unknown exception'})';
    } else if (request.count !=
        switch (request.registerStart) {
          0 => 8,
          9 => 4,
          15 => 22,
          _ => null,
        }) {
      issue = 'Unsupported Modbus register block/count; raw data retained';
    } else {
      final payload = Uint8List.sublistView(frame, 3, frame.length - 2);
      final words = ByteData.sublistView(payload);
      switch (request.registerStart) {
        case 0:
          _basic[request.address] = Uint8List.fromList(payload);
          description +=
              '; basic values received, awaiting cell/temperature block';
        case 9:
          warnings = BatteryWarnings(
            cells: const [],
            temperatures: const [],
            registers: Map.unmodifiable({
              'Warnings': words.getUint16(0),
              'Protections': words.getUint16(2),
              'Status/fault': words.getUint16(4),
              'Balance': words.getUint16(6),
            }),
            flag: null,
            pack: request.address,
            extension: '',
            source: MeasurementSource.modbus,
          );
        case 15:
          final basic = _basic.remove(request.address);
          if (basic == null) {
            issue =
                '${request.description}: no basic measurements from this sweep';
          } else {
            final values = ByteData.sublistView(basic);
            measurements = Measurements(
              cells: List.unmodifiable(
                List.generate(16, (i) => words.getUint16(i * 2) / 1000),
              ),
              temperatures: List.unmodifiable(
                List.generate(6, (i) => words.getInt16(32 + i * 2) / 10),
              ),
              current: values.getInt16(0) / 100,
              voltage: values.getUint16(2) / 100,
              remainingAh: values.getUint16(8) / 100,
              fullAh: values.getUint16(10) / 100,
              cycles: values.getUint16(14),
              flag: null,
              pack: request.address,
              extraMarker: null,
              extension: '',
              source: MeasurementSource.modbus,
              reportedSoc: values.getUint16(4).toDouble(),
              reportedSoh: values.getUint16(6).toDouble(),
              designAh: values.getUint16(12) / 100,
            );
          }
        default:
          issue =
              'Unsupported Modbus register block ${request.registerStart}; raw data retained';
      }
    }
    return ProtocolEvent(
      description: description,
      raw: raw,
      address: request.address,
      command: 3,
      registerStart: request.registerStart,
      response: true,
      valid: true,
      issue: issue,
      measurements: measurements,
      warnings: warnings,
    );
  }
}
