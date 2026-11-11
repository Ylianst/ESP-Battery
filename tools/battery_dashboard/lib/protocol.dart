import 'dart:typed_data';

String hexByte(int value) =>
    value.toRadixString(16).padLeft(2, '0').toUpperCase();
String hexBytes(Iterable<int> values) => values.map(hexByte).join();

const commandNames = {
  0x42: 'Read measurements',
  0x44: 'Read warnings/status',
  0x90: 'Read pack number',
};

const statusNames = [
  'Charge-current warning',
  'Pack-voltage warning',
  'Discharge-current warning',
  'Protection 1',
  'Protection 2',
  'Instruction',
  'Control',
  'Fault',
  'Balance 1',
  'Balance 2',
  'Warning 1',
  'Warning 2',
];

enum MeasurementSource { pace, modbus }

class Measurements {
  Measurements({
    required this.cells,
    required this.temperatures,
    required this.current,
    required this.voltage,
    required this.remainingAh,
    required this.fullAh,
    required this.cycles,
    required this.flag,
    required this.pack,
    required this.extraMarker,
    required this.extension,
    this.source = MeasurementSource.pace,
    this.reportedSoc,
    this.reportedSoh,
    this.designAh,
  });

  final List<double> cells;
  final List<double> temperatures;
  final double current;
  final double voltage;
  final double remainingAh;
  final double fullAh;
  final int cycles;
  final int? flag;
  final int pack;
  final int? extraMarker;
  final String extension;
  final MeasurementSource source;
  final double? reportedSoc;
  final double? reportedSoh;
  final double? designAh;

  double? get soc =>
      reportedSoc ?? (fullAh > 0 ? remainingAh / fullAh * 100 : null);
  double get power => voltage * current;
  double get minCell => cells.reduce((a, b) => a < b ? a : b);
  double get maxCell => cells.reduce((a, b) => a > b ? a : b);
  double get spreadMv => (maxCell - minCell) * 1000;

  factory Measurements.parse(Uint8List info, int address) {
    final reader = _PayloadReader(info);
    final flag = reader.byte();
    final pack = reader.byte();
    if (pack != address) {
      throw const FormatException(
        'Unsupported multi-pack/vendor measurement layout',
      );
    }
    final count = reader.byte();
    if (count < 1 || count > 32) {
      throw FormatException('Invalid cell count: $count');
    }
    final cells = List.generate(count, (_) => reader.word() / 1000);
    final tempCount = reader.byte();
    if (tempCount > 16) {
      throw FormatException('Invalid temperature count: $tempCount');
    }
    final temperatures = List.generate(
      tempCount,
      (_) => (reader.word() - 2731) / 10,
    );
    final unsignedCurrent = reader.word();
    final current =
        (unsignedCurrent >= 0x8000
            ? unsignedCurrent - 0x10000
            : unsignedCurrent) /
        100;
    final voltage = reader.word() / 1000;
    final remainingAh = reader.word() / 100;
    final marker = reader.byte();
    final fullAh = reader.word() / 100;
    final cycles = reader.word();
    return Measurements(
      cells: List.unmodifiable(cells),
      temperatures: List.unmodifiable(temperatures),
      current: current,
      voltage: voltage,
      remainingAh: remainingAh,
      fullAh: fullAh,
      cycles: cycles,
      flag: flag,
      pack: pack,
      extraMarker: marker,
      extension: reader.remainingHex,
    );
  }
}

class BatteryWarnings {
  BatteryWarnings({
    required this.cells,
    required this.temperatures,
    required this.registers,
    required this.flag,
    required this.pack,
    required this.extension,
    this.source = MeasurementSource.pace,
  });

  final List<int> cells;
  final List<int> temperatures;
  final Map<String, int> registers;
  final int? flag;
  final int pack;
  final String extension;
  final MeasurementSource source;

  // Instruction, control and balancing bits are not themselves alarms.
  int get nonzeroWarnings =>
      cells.where((value) => value != 0).length +
      temperatures.where((value) => value != 0).length +
      registers.entries
          .where(
            (entry) =>
                ![
                  'Instruction',
                  'Control',
                  'Balance 1',
                  'Balance 2',
                  'Status/fault',
                  'Balance',
                ].contains(entry.key) &&
                !entry.key.startsWith('Raw status ') &&
                entry.value != 0,
          )
          .length;

  factory BatteryWarnings.parse(
    Uint8List info,
    int address, {
    int version = 0x25,
  }) {
    final reader = _PayloadReader(info);
    final flag = reader.byte();
    final pack = reader.byte();
    if (pack != address) {
      throw const FormatException(
        'Unsupported multi-pack/vendor warning layout',
      );
    }
    final count = reader.byte();
    if (count < 1 || count > 32) {
      throw FormatException('Invalid warning cell count: $count');
    }
    final cells = List.generate(count, (_) => reader.byte());
    final tempCount = reader.byte();
    if (tempCount > 16) {
      throw FormatException('Invalid warning temperature count: $tempCount');
    }
    final temperatures = List.generate(tempCount, (_) => reader.byte());
    final names = version == 0x20
        ? List.generate(8, (index) => 'Raw status ${index + 1}')
        : statusNames;
    final registers = {for (final name in names) name: reader.byte()};
    return BatteryWarnings(
      cells: List.unmodifiable(cells),
      temperatures: List.unmodifiable(temperatures),
      registers: Map.unmodifiable(registers),
      flag: flag,
      pack: pack,
      extension: reader.remainingHex,
    );
  }
}

class _PayloadReader {
  _PayloadReader(this.data);
  final Uint8List data;
  int offset = 0;

  int byte() {
    if (offset >= data.length) {
      throw const FormatException('Truncated payload');
    }
    return data[offset++];
  }

  int word() => (byte() << 8) | byte();
  String get remainingHex => hexBytes(data.skip(offset));
}

class ProtocolEvent {
  const ProtocolEvent({
    required this.description,
    required this.raw,
    this.address,
    this.command,
    this.response = false,
    this.valid = false,
    this.issue,
    this.measurements,
    this.warnings,
    this.packNumber,
    this.registerStart,
  });

  final String description;
  final String raw;
  final int? address;
  final int? command;
  final bool response;
  final bool valid;
  final String? issue;
  final Measurements? measurements;
  final BatteryWarnings? warnings;
  final int? packNumber;
  final int? registerStart;
}

class _Pending {
  const _Pending(this.command, this.at);
  final int command;
  final DateTime at;
}

class BatteryProtocol {
  BatteryProtocol({this.responseTimeout = const Duration(seconds: 5)});
  final Duration responseTimeout;
  String _frame = '';
  final Map<int, _Pending> _pending = {};

  List<ProtocolEvent> add(List<int> data, {required DateTime at}) {
    final events = <ProtocolEvent>[];
    final noise = <int>[];
    for (final byte in data) {
      if (byte == 0x7e) {
        if (_frame.isNotEmpty) {
          events.add(
            _issue(
              'Discarded incomplete frame before new start delimiter',
              _frame,
            ),
          );
        }
        _frame = '~';
      } else if (_frame.isNotEmpty) {
        if (byte == 0x0d) {
          events.add(_decode(_frame, at));
          _frame = '';
        } else {
          _frame += String.fromCharCode(byte);
          if (_frame.length > 4113) {
            events.add(_issue('Frame exceeds maximum protocol length', _frame));
            _frame = '';
          }
        }
      } else if (byte != 0x0a && byte != 0x0d) {
        noise.add(byte);
      }
    }
    if (noise.isNotEmpty) {
      events.add(_issue('Unframed bytes: ${hexBytes(noise)}', ''));
    }
    return events;
  }

  ProtocolEvent? finish() {
    if (_frame.isEmpty) return null;
    final event = _issue('Incomplete frame at disconnect', _frame);
    _frame = '';
    return event;
  }

  ProtocolEvent _issue(String message, String raw) =>
      ProtocolEvent(description: message, raw: raw, issue: message);

  ProtocolEvent _decode(String raw, DateTime at) {
    try {
      if (!RegExp(r'^~[0-9a-fA-F]{16,}$').hasMatch(raw) || raw.length.isEven) {
        throw const FormatException('Invalid ASCII-hex frame');
      }
      final body = raw.substring(1, raw.length - 4);
      int field(int start, int end) =>
          int.parse(body.substring(start, end), radix: 16);
      final length = field(8, 12);
      final infoLength = length & 0x0fff;
      final check = -(infoLength + (infoLength >> 4) + (infoLength >> 8)) & 15;
      if (length >> 12 != check) {
        throw const FormatException('Length checksum mismatch');
      }
      if (body.length != 12 + infoLength || infoLength.isOdd) {
        throw const FormatException('Payload length mismatch');
      }
      final sum = body.codeUnits.fold(0, (a, b) => a + b);
      if ((-sum & 0xffff) !=
          int.parse(raw.substring(raw.length - 4), radix: 16)) {
        throw const FormatException('Frame checksum mismatch');
      }
      final version = field(0, 2);
      final address = field(2, 4);
      final type = field(4, 6);
      final code = field(6, 8);
      final info = Uint8List.fromList(
        List.generate(infoLength ~/ 2, (i) => field(12 + i * 2, 14 + i * 2)),
      );
      if ((version != 0x25 && version != 0x20) || type != 0x46) {
        return _issue(
          'Unsupported protocol ${hexByte(version)}/CID1 ${hexByte(type)}',
          raw,
        );
      }
      final pending = _pending[address];
      final response =
          code <= 0x0f ||
          (code == 0x90 &&
              pending != null &&
              (pending.command != 0x90 || info.isNotEmpty));
      if (!response) {
        _pending[address] = _Pending(code, at);
        return ProtocolEvent(
          description:
              'Battery $address: request ${commandNames[code] ?? 'unknown command'} (0x${hexByte(code)})',
          raw: raw,
          address: address,
          command: code,
          valid: true,
        );
      }
      _pending.remove(address);
      final matched =
          pending != null &&
          !at.isBefore(pending.at) &&
          at.difference(pending.at) <= responseTimeout;
      final command = matched ? pending.command : null;
      final name = commandNames[command] ?? 'unmatched/unknown request';
      if (code != 0) {
        return ProtocolEvent(
          description:
              'Battery $address: $name failed (return code 0x${hexByte(code)})',
          raw: raw,
          address: address,
          command: command,
          response: true,
          valid: true,
          issue: 'Battery $address returned error 0x${hexByte(code)}',
        );
      }
      Measurements? measurements;
      BatteryWarnings? warnings;
      String? issue;
      try {
        if (command == 0x42) measurements = Measurements.parse(info, address);
        if (command == 0x44) {
          warnings = BatteryWarnings.parse(info, address, version: version);
        }
      } on FormatException catch (error) {
        issue = 'Battery $address: ${error.message}; payload=${hexBytes(info)}';
      }
      return ProtocolEvent(
        description: 'Battery $address: response $name; checksum OK',
        raw: raw,
        address: address,
        command: command,
        response: true,
        valid: true,
        issue: issue,
        measurements: measurements,
        warnings: warnings,
        packNumber: command == 0x90 && info.length == 1 ? info[0] : null,
      );
    } on FormatException catch (error) {
      return _issue(error.message, raw);
    }
  }
}
