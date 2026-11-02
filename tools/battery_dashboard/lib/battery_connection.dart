import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'protocol.dart';

enum LinkState { disconnected, connecting, connected }

class VoltageSample {
  const VoltageSample(this.at, this.voltage);
  final DateTime at;
  final double voltage;
}

class BatteryState {
  BatteryState(this.address);
  final int address;
  Measurements? measurements;
  BatteryWarnings? warnings;
  DateTime? measurementAt;
  DateTime? warningsAt;
  DateTime? lastSeen;
  int? packNumber;
  String lastFrame = '';
  final List<VoltageSample> history = [];

  bool fresh(DateTime now, bool connected) =>
      connected &&
      measurementAt != null &&
      now.difference(measurementAt!) < const Duration(seconds: 30);

  bool warningsFresh(DateTime now, bool connected) =>
      connected &&
      warningsAt != null &&
      now.difference(warningsAt!) < const Duration(seconds: 30);
}

class TrafficEntry {
  const TrafficEntry(
    this.at,
    this.message, {
    this.raw = '',
    this.issue = false,
  });
  final DateTime at;
  final String message;
  final String raw;
  final bool issue;
}

class BatteryConnection extends ChangeNotifier {
  LinkState state = LinkState.disconnected;
  String message = 'Ready to connect';
  String endpoint = '';
  final Map<int, BatteryState> batteries = {};
  final List<TrafficEntry> traffic = [];
  int validFrames = 0;
  int issues = 0;
  int receivedBytes = 0;
  DateTime? lastTrafficAt;

  Socket? _socket;
  StreamSubscription<List<int>>? _subscription;
  Timer? _timer;
  BatteryProtocol _protocol = BatteryProtocol();
  int _generation = 0;

  bool get connected => state == LinkState.connected;

  void _log(String text, {String raw = '', bool issue = false}) {
    traffic.insert(
      0,
      TrafficEntry(DateTime.now(), text, raw: raw, issue: issue),
    );
    if (traffic.length > 80) traffic.removeLast();
  }

  Future<void> connect(String host, int port) async {
    if (host.trim().isEmpty || port < 1 || port > 65535) {
      message = 'Enter a hostname and a port between 1 and 65535.';
      _log(message, issue: true);
      notifyListeners();
      return;
    }
    _close();
    final attempt = _generation;
    batteries.clear();
    traffic.clear();
    validFrames = 0;
    issues = 0;
    receivedBytes = 0;
    lastTrafficAt = null;
    endpoint = '${host.trim()}:$port';
    state = LinkState.connecting;
    message = 'Connecting to $endpoint...';
    _log(message);
    notifyListeners();
    try {
      final socket = await Socket.connect(
        host.trim(),
        port,
        timeout: const Duration(seconds: 10),
      );
      if (attempt != _generation) {
        socket.destroy();
        return;
      }
      _socket = socket;
      state = LinkState.connected;
      message = 'Listening for battery replies';
      _log('Connected to $endpoint (read-only)');
      _timer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => notifyListeners(),
      );
      _subscription = socket.listen(
        (data) {
          if (attempt != _generation) return;
          final now = DateTime.now();
          lastTrafficAt = now;
          receivedBytes += data.length;
          for (final event in _protocol.add(data, at: now)) {
            if (event.valid) validFrames++;
            if (event.issue != null) issues++;
            _log(
              event.issue ?? event.description,
              raw: event.raw,
              issue: event.issue != null,
            );
            // Address scans are requests, not evidence that a battery exists.
            if (!event.response || !event.valid || event.address == null) {
              continue;
            }
            final battery = batteries.putIfAbsent(
              event.address!,
              () => BatteryState(event.address!),
            );
            battery.lastSeen = now;
            battery.lastFrame = event.raw;
            if (event.measurements case final measurements?) {
              battery.measurements = measurements;
              battery.measurementAt = now;
              battery.history.add(VoltageSample(now, measurements.voltage));
              if (battery.history.length > 120) battery.history.removeAt(0);
            }
            if (event.warnings case final warnings?) {
              battery.warnings = warnings;
              battery.warningsAt = now;
            }
            if (event.packNumber != null) battery.packNumber = event.packNumber;
          }
          notifyListeners();
        },
        onError: (Object error) {
          if (attempt != _generation) return;
          _close();
          message = 'Connection error: $error';
          _log(message, issue: true);
          notifyListeners();
        },
        onDone: () {
          if (attempt != _generation) return;
          _close();
          message = 'ESP32 closed the connection. Reconnect to resume.';
          _log(message, issue: true);
          notifyListeners();
        },
        cancelOnError: true,
      );
      notifyListeners();
    } on SocketException catch (error) {
      _connectFailed(attempt, 'Cannot connect to $endpoint: ${error.message}');
    } on TimeoutException {
      _connectFailed(
        attempt,
        'Connection to $endpoint timed out after 10 seconds.',
      );
    }
  }

  void _connectFailed(int attempt, String error) {
    if (attempt != _generation) return;
    _close();
    message = error;
    _log(error, issue: true);
    notifyListeners();
  }

  void disconnect() {
    _close();
    message =
        'Disconnected. Previous readings are retained but no longer live.';
    _log(message);
    notifyListeners();
  }

  void _close() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    unawaited(_subscription?.cancel());
    _subscription = null;
    _socket?.destroy();
    _socket = null;
    final partial = _protocol.finish();
    if (partial != null) {
      issues++;
      _log(partial.description, raw: partial.raw, issue: true);
    }
    _protocol = BatteryProtocol();
    state = LinkState.disconnected;
  }

  @override
  void dispose() {
    _close();
    super.dispose();
  }
}
