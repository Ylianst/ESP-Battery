import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'battery_connection.dart';
import 'charts.dart';
import 'protocol.dart';
import 'polling.dart';

void main() => runApp(const BatteryDashboard());

class BatteryDashboard extends StatelessWidget {
  const BatteryDashboard({super.key, this.connection});
  final BatteryConnection? connection;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ESP Battery Dashboard',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        scaffoldBackgroundColor: canvasColor,
        colorScheme: ColorScheme.fromSeed(
          seedColor: mint,
          brightness: Brightness.dark,
          surface: panelColor,
          primary: mint,
          secondary: violet,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: canvasColor.withValues(alpha: 0.7),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 16,
          ),
        ),
        expansionTileTheme: const ExpansionTileThemeData(
          shape: Border(),
          collapsedShape: Border(),
          iconColor: muted,
          collapsedIconColor: muted,
        ),
      ),
      home: DashboardPage(connection: connection),
    );
  }
}

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key, this.connection});
  final BatteryConnection? connection;

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  late final BatteryConnection connection;
  final _host = TextEditingController(text: 'sunpower.local');
  final _port = TextEditingController(text: '1234');
  final _addresses = TextEditingController(text: '1,2,3,4');
  bool _pollingEnabled = false;
  PollingProtocol _pollingProtocol = PollingProtocol.modbus;
  final _form = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    connection = widget.connection ?? BatteryConnection();
  }

  @override
  void dispose() {
    if (widget.connection == null) connection.dispose();
    _host.dispose();
    _port.dispose();
    _addresses.dispose();
    super.dispose();
  }

  void _connect() {
    if (_form.currentState!.validate()) {
      final polling = _pollingEnabled
          ? PollingSettings(
              protocol: _pollingProtocol,
              addresses: PollingSettings.parseAddresses(
                _addresses.text,
                _pollingProtocol,
              ),
            )
          : null;
      unawaited(
        connection.connect(
          _host.text.trim(),
          int.parse(_port.text),
          polling: polling,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: connection,
      builder: (context, _) {
        final now = DateTime.now();
        final batteries = connection.batteries.values.toList()
          ..sort((a, b) => a.address.compareTo(b.address));
        final live = batteries
            .where((b) => b.fresh(now, connection.connected))
            .toList();
        final socs = live
            .map((b) => b.measurements!.soc)
            .whereType<double>()
            .toList();
        final averageSoc = socs.isEmpty
            ? null
            : socs.reduce((a, b) => a + b) / socs.length;
        final power = live.fold(
          0.0,
          (total, b) => total + b.measurements!.power,
        );
        return Scaffold(
          body: SafeArea(
            child: SingleChildScrollView(
              key: const Key('dashboard-scroll'),
              padding: const EdgeInsets.all(24),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1440),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _header(),
                      const SizedBox(height: 24),
                      _connectionPanel(),
                      const SizedBox(height: 20),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final columns = constraints.maxWidth < 600 ? 2 : 4;
                          final width =
                              (constraints.maxWidth - (columns - 1) * 12) /
                              columns;
                          return Wrap(
                            spacing: 12,
                            runSpacing: 12,
                            children: [
                              _summary(
                                'LIVE BATTERIES',
                                '${live.length}',
                                '${batteries.length} discovered',
                                Icons.battery_std_rounded,
                                mint,
                                width,
                              ),
                              _summary(
                                'AVERAGE SOC',
                                averageSoc == null
                                    ? '--'
                                    : '${averageSoc.toStringAsFixed(1)}%',
                                'Reported / calculated by protocol',
                                Icons.donut_large_rounded,
                                violet,
                                width,
                              ),
                              _summary(
                                'REPORTED POWER',
                                live.isEmpty
                                    ? '--'
                                    : '${power.toStringAsFixed(0)} W',
                                'Sum of live packs (signed)',
                                Icons.bolt_rounded,
                                sky,
                                width,
                              ),
                              _summary(
                                'VALID FRAMES',
                                '${connection.validFrames}',
                                '${connection.issues} protocol issues',
                                Icons.hub_outlined,
                                connection.issues == 0 ? mint : amber,
                                width,
                              ),
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 28),
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Battery fleet',
                              style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Text(
                            '${batteries.length} ${batteries.length == 1 ? 'PACK' : 'PACKS'}',
                            style: const TextStyle(
                              color: muted,
                              fontSize: 11,
                              letterSpacing: 1.5,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Only responding batteries appear. Readings older than 30 seconds are marked stale.',
                        style: TextStyle(color: muted, fontSize: 12),
                      ),
                      const SizedBox(height: 16),
                      if (batteries.isEmpty) _emptyState(),
                      for (final battery in batteries)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 18),
                          child: BatteryCard(
                            battery: battery,
                            connected: connection.connected,
                            now: now,
                          ),
                        ),
                      const SizedBox(height: 8),
                      _trafficPanel(),
                      const SizedBox(height: 20),
                      const Text(
                        'READ-ONLY TELEMETRY  /  ASCII PACE + MODBUS RTU  /  OPTIONAL ACTIVE POLLING',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: muted,
                          fontSize: 10,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _header() => Wrap(
    alignment: WrapAlignment.spaceBetween,
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: 16,
    runSpacing: 16,
    children: [
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    mint.withValues(alpha: 0.25),
                    sky.withValues(alpha: 0.08),
                  ],
                ),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: mint.withValues(alpha: 0.25)),
              ),
              child: const Icon(
                Icons.battery_charging_full_rounded,
                color: mint,
                size: 29,
              ),
            ),
            const SizedBox(width: 14),
            const Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'ESP BATTERY',
                    style: TextStyle(
                      color: mint,
                      fontSize: 11,
                      letterSpacing: 3,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'Energy dashboard',
                    style: TextStyle(
                      fontSize: 25,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.5,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      const _Badge(
        label: 'RS485 / TCP BRIDGE',
        color: sky,
        icon: Icons.lan_outlined,
      ),
    ],
  );

  Widget _connectionPanel() {
    final busy = connection.state != LinkState.disconnected;
    final connecting = connection.state == LinkState.connecting;
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.router_rounded, size: 20, color: mint),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'ESP32 connection',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              _Badge(
                label: connecting
                    ? 'CONNECTING'
                    : connection.connected
                    ? 'CONNECTED'
                    : 'OFFLINE',
                color: connecting
                    ? amber
                    : connection.connected
                    ? mint
                    : muted,
                icon: Icons.circle,
                small: true,
              ),
            ],
          ),
          const SizedBox(height: 18),
          Form(
            key: _form,
            child: Column(
              children: [
                LayoutBuilder(
                  builder: (context, constraints) {
                    final host = TextFormField(
                      controller: _host,
                      enabled: !busy,
                      decoration: const InputDecoration(
                        labelText: 'Hostname or IP address',
                        prefixIcon: Icon(Icons.dns_outlined),
                      ),
                      autocorrect: false,
                      validator: (value) {
                        final text = value?.trim() ?? '';
                        if (text.isEmpty || RegExp(r'\s|/').hasMatch(text)) {
                          return 'Enter a hostname or IP (no URL or port)';
                        }
                        return null;
                      },
                      onFieldSubmitted: (_) => _connect(),
                    );
                    final port = TextFormField(
                      controller: _port,
                      enabled: !busy,
                      decoration: const InputDecoration(labelText: 'TCP port'),
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      validator: (value) {
                        final number = int.tryParse(value ?? '');
                        return number == null || number < 1 || number > 65535
                            ? 'Use 1 - 65535'
                            : null;
                      },
                      onFieldSubmitted: (_) => _connect(),
                    );
                    final button = SizedBox(
                      height: 54,
                      child: FilledButton.icon(
                        onPressed: busy ? connection.disconnect : _connect,
                        style: FilledButton.styleFrom(
                          backgroundColor: busy
                              ? Colors.white.withValues(alpha: 0.1)
                              : mint,
                          foregroundColor: busy ? Colors.white : canvasColor,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        icon: Icon(
                          busy
                              ? Icons.link_off_rounded
                              : Icons.power_settings_new_rounded,
                        ),
                        label: Text(
                          connecting
                              ? 'Cancel'
                              : connection.connected
                              ? 'Disconnect'
                              : 'Connect',
                        ),
                      ),
                    );
                    if (constraints.maxWidth < 620) {
                      return Column(
                        children: [
                          host,
                          const SizedBox(height: 12),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(child: port),
                              const SizedBox(width: 12),
                              SizedBox(width: 150, child: button),
                            ],
                          ),
                        ],
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: host),
                        const SizedBox(width: 12),
                        SizedBox(width: 140, child: port),
                        const SizedBox(width: 12),
                        SizedBox(width: 164, child: button),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 12),
                _pollingControls(busy),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                connection.connected
                    ? Icons.sensors_rounded
                    : Icons.info_outline,
                size: 16,
                color: connection.connected ? mint : muted,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  connection.message,
                  key: const Key('connection-message'),
                  style: const TextStyle(color: muted, fontSize: 12),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _pollingControls(bool busy) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Material(
        color: Colors.transparent,
        child: SwitchListTile(
          key: const Key('enable-polling'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Enable active polling'),
          subtitle: const Text('Off: passive monitor, sends no bytes.'),
          value: _pollingEnabled,
          onChanged: busy
              ? null
              : (value) => setState(() => _pollingEnabled = value),
        ),
      ),
      if (_pollingEnabled) ...[
        const SizedBox(height: 8),
        DropdownButtonFormField<PollingProtocol>(
          key: const Key('polling-protocol'),
          initialValue: _pollingProtocol,
          decoration: const InputDecoration(labelText: 'Polling protocol'),
          items: const [
            DropdownMenuItem(
              value: PollingProtocol.modbus,
              child: Text('Modbus RTU (PACE register map)'),
            ),
            DropdownMenuItem(
              value: PollingProtocol.pace,
              child: Text('ASCII PACE (25 / 20 replies)'),
            ),
          ],
          onChanged: busy
              ? null
              : (value) {
                  if (value != null) setState(() => _pollingProtocol = value);
                },
          isExpanded: true,
        ),
        const SizedBox(height: 12),
        TextFormField(
          key: const Key('polling-addresses'),
          controller: _addresses,
          enabled: !busy,
          decoration: InputDecoration(
            labelText: 'Battery addresses',
            helperText: _pollingProtocol == PollingProtocol.modbus
                ? 'Comma-separated slaves 1-247; no broadcast address 0'
                : 'Comma-separated addresses 0-15; individual pack reads',
          ),
          validator: (value) {
            try {
              PollingSettings.parseAddresses(value ?? '', _pollingProtocol);
              return null;
            } on FormatException catch (error) {
              return error.message;
            }
          },
          onFieldSubmitted: (_) => _connect(),
        ),
        const SizedBox(height: 12),
        const Text(
          'Read-only requests, one at a time. Stop other polling masters on this RS485 bus. '
          'Modbus requires the matching battery inverter protocol; ASCII PACE is different. '
          'Disconnect before changing these options.',
          style: TextStyle(color: amber, fontSize: 12),
        ),
      ],
    ],
  );

  Widget _summary(
    String title,
    String value,
    String subtitle,
    IconData icon,
    Color color,
    double width,
  ) => SizedBox(
    width: width,
    child: _Panel(
      padding: 18,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: muted,
                    fontSize: 10,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            value,
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
          const SizedBox(height: 4),
          Text(subtitle, style: const TextStyle(color: muted, fontSize: 11)),
        ],
      ),
    ),
  );

  Widget _emptyState() => _Panel(
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        children: [
          Icon(
            connection.connected
                ? Icons.sensors_rounded
                : Icons.battery_unknown_rounded,
            size: 52,
            color: mint.withValues(alpha: 0.6),
          ),
          const SizedBox(height: 18),
          Text(
            connection.connected
                ? 'Listening for your batteries'
                : 'Your batteries, at a glance',
            style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w600),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 10),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 500),
            child: Text(
              connection.connected
                  ? connection.polling == null
                        ? 'Waiting for complete request/reply pairs. The bus must already be polled by an inverter or another controller. Address scans alone will not add batteries.'
                        : 'Polling the selected addresses. Only validated replies add batteries. Check the traffic inspector for timeouts, protocol errors or incomplete telemetry.'
                  : 'Connect to the ESP32 bridge to discover responding packs and explore cell voltages, temperatures, capacities and status.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: muted, height: 1.6, fontSize: 13),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _trafficPanel() => _Panel(
    padding: 4,
    child: ExpansionTile(
      title: const Text(
        'Protocol & traffic inspector',
        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        '${connection.receivedBytes} bytes received / ${connection.issues} issues / latest 80 events',
        style: const TextStyle(color: muted, fontSize: 11),
      ),
      leading: const Icon(Icons.terminal_rounded, color: sky),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        const Text(
          'Unknown payloads and corrupt frames remain visible here. Active polling sends one read at a time with a 2-second response timeout; passive ASCII matching uses 5 seconds.',
          style: TextStyle(color: muted, fontSize: 12),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 260,
          child: connection.traffic.isEmpty
              ? const Center(
                  child: Text('No traffic yet', style: TextStyle(color: muted)),
                )
              : ListView.separated(
                  itemCount: connection.traffic.length,
                  separatorBuilder: (_, _) => const Divider(height: 18),
                  itemBuilder: (context, index) {
                    final entry = connection.traffic[index];
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SelectableText(
                          '${_time(entry.at)}  ${entry.message}',
                          style: TextStyle(
                            color: entry.issue ? amber : muted,
                            fontSize: 11,
                          ),
                        ),
                        if (entry.raw.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          SelectableText(
                            _visible(entry.raw),
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                              color: sky,
                            ),
                          ),
                        ],
                      ],
                    );
                  },
                ),
        ),
      ],
    ),
  );
}

class BatteryCard extends StatelessWidget {
  const BatteryCard({
    super.key,
    required this.battery,
    required this.connected,
    required this.now,
  });
  final BatteryState battery;
  final bool connected;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final data = battery.measurements;
    final fresh = battery.fresh(now, connected);
    final warningsFresh = battery.warningsFresh(now, connected);
    final warning = battery.warnings;
    final modbus =
        data?.source == MeasurementSource.modbus ||
        warning?.source == MeasurementSource.modbus;
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: mint.withValues(alpha: 0.09),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(
                  Icons.battery_5_bar_rounded,
                  size: 28,
                  color: mint,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Battery ${battery.address}',
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'ADDRESS 0x${hexByte(battery.address)} / ${age(battery.measurementAt ?? battery.lastSeen, now)}',
                      style: const TextStyle(
                        color: muted,
                        fontSize: 10,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ],
                ),
              ),
              _Badge(
                label: fresh
                    ? 'LIVE'
                    : data == null
                    ? 'NO TELEMETRY'
                    : 'STALE',
                color: fresh ? mint : amber,
                icon: Icons.circle,
                small: true,
              ),
            ],
          ),
          const SizedBox(height: 18),
          if (data == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text(
                'Battery replied. Waiting for supported measurement data...',
                style: TextStyle(color: muted),
              ),
            )
          else ...[
            LayoutBuilder(
              builder: (context, constraints) {
                final metrics = Wrap(
                  spacing: 24,
                  runSpacing: 18,
                  children: [
                    _metric(
                      'PACK VOLTAGE',
                      data.voltage.toStringAsFixed(3),
                      'V',
                      sky,
                    ),
                    _metric(
                      'SIGNED CURRENT',
                      data.current.toStringAsFixed(2),
                      'A',
                      mint,
                    ),
                    _metric(
                      'PACK POWER',
                      data.power.toStringAsFixed(1),
                      'W',
                      violet,
                    ),
                    _metric(
                      'REMAINING / FULL',
                      '${data.remainingAh.toStringAsFixed(2)} / ${data.fullAh.toStringAsFixed(2)}',
                      'Ah',
                      Colors.white,
                    ),
                    _metric(
                      'CELL SPREAD',
                      data.spreadMv.toStringAsFixed(0),
                      'mV',
                      sky,
                    ),
                    _metric('CYCLES', '${data.cycles}', '', Colors.white),
                  ],
                );
                if (constraints.maxWidth < 500) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: SocGauge(
                          value: data.soc,
                          reported: data.reportedSoc != null,
                        ),
                      ),
                      const SizedBox(height: 20),
                      metrics,
                    ],
                  );
                }
                return Row(
                  children: [
                    Expanded(child: metrics),
                    const SizedBox(width: 24),
                    SocGauge(
                      value: data.soc,
                      reported: data.reportedSoc != null,
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 12),
            Text(
              data.reportedSoc == null
                  ? 'SOC = remaining / full capacity. Current polarity and vendor-specific fields are not inferred.'
                  : 'SOC is reported by the battery via Modbus, not calculated from capacity. Current is signed.',
              style: const TextStyle(color: muted, fontSize: 10),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Divider(color: Color(0xFF243344)),
            ),
            LayoutBuilder(
              builder: (context, constraints) {
                final cells = CellVoltageChart(
                  values: data.cells,
                  warningCodes: warningsFresh ? warning!.cells : const [],
                );
                final temperatures = Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TemperatureChart(
                      values: data.temperatures,
                      labels: data.source == MeasurementSource.modbus
                          ? const ['Battery 1', 'Battery 2', 'Battery 3', 'Battery 4', 'MOSFET', 'Environment']
                          : null,
                      warningCodes: warningsFresh
                          ? warning!.temperatures
                          : const [],
                    ),
                    const SizedBox(height: 28),
                    VoltageTrend(samples: battery.history),
                  ],
                );
                if (constraints.maxWidth < 850) {
                  return Column(
                    children: [cells, const SizedBox(height: 28), temperatures],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 3, child: cells),
                    const SizedBox(width: 32),
                    Expanded(flex: 2, child: temperatures),
                  ],
                );
              },
            ),
          ],
          const SizedBox(height: 18),
          _warningSection(warning, warningsFresh),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text(
              'Protocol details & vendor fields',
              style: TextStyle(color: muted, fontSize: 12),
            ),
            childrenPadding: const EdgeInsets.only(bottom: 12),
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                modbus
                    ? 'Modbus RTU / function 03 / PACE holding-register map'
                    : 'PACE 20/25 / CID1 0x46 / pack number field: ${battery.packNumber ?? 'not observed'}',
                style: const TextStyle(color: muted, fontSize: 11),
              ),
              if (data != null && data.source == MeasurementSource.pace) ...[
                const SizedBox(height: 8),
                SelectableText(
                  'Measurement flag ${_hexField(data.flag)} / pack 0x${hexByte(data.pack)} / extra marker ${_hexField(data.extraMarker)}',
                  style: const TextStyle(fontSize: 11, color: muted),
                ),
                const SizedBox(height: 4),
                SelectableText(
                  'Measurement extension: ${data.extension.isEmpty ? '(empty)' : data.extension}',
                  style: const TextStyle(
                    fontSize: 11,
                    color: sky,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
              if (data != null && data.source == MeasurementSource.modbus) ...[
                const SizedBox(height: 8),
                Text(
                  'Reported SOH: ${data.reportedSoh?.toStringAsFixed(0) ?? 'not provided'}% / design capacity: ${data.designAh?.toStringAsFixed(2) ?? 'not provided'} Ah',
                  style: const TextStyle(color: muted, fontSize: 11),
                ),
                const Text(
                  'Temperature order: battery 1-4, MOSFET, environment. No per-cell warning codes are provided by this register map.',
                  style: TextStyle(color: muted, fontSize: 11),
                ),
              ],
              if (warning != null &&
                  warning.source == MeasurementSource.pace) ...[
                const SizedBox(height: 8),
                SelectableText(
                  'Warning flag ${_hexField(warning.flag)} / pack 0x${hexByte(warning.pack)} / extension: ${warning.extension.isEmpty ? '(empty)' : warning.extension}',
                  style: const TextStyle(fontSize: 11, color: muted),
                ),
              ],
              const SizedBox(height: 8),
              Text(
                modbus
                    ? 'Latest validated reply (RTU hex)'
                    : 'Latest validated reply (ASCII)',
                style: const TextStyle(color: muted, fontSize: 11),
              ),
              const SizedBox(height: 4),
              SelectableText(
                _visible(battery.lastFrame),
                style: const TextStyle(
                  color: sky,
                  fontSize: 11,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _metric(String label, String value, String unit, Color color) =>
      ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 126),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: const TextStyle(
                color: muted,
                fontSize: 10,
                letterSpacing: 0.8,
              ),
            ),
            const SizedBox(height: 6),
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: value,
                    style: TextStyle(
                      color: color,
                      fontSize: 23,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  TextSpan(
                    text: unit.isEmpty ? '' : ' $unit',
                    style: const TextStyle(color: muted, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      );

  Widget _warningSection(BatteryWarnings? warnings, bool fresh) {
    final count = warnings?.nonzeroWarnings;
    final title = warnings == null
        ? 'Warning data not received'
        : !fresh
        ? 'Warning data stale / ${age(battery.warningsAt, now)}'
        : count == 0
        ? 'Warning fields all zero'
        : '$count nonzero warning fields';
    final color = fresh && count == 0 ? mint : amber;
    return Container(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.045),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.14)),
      ),
      child: ExpansionTile(
        leading: Icon(
          fresh && count == 0 ? Icons.verified_outlined : Icons.info_outline,
          color: color,
          size: 20,
        ),
        title: Text(
          title,
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Text(
          warnings == null ? 'Waiting for a warning/status reply' : 'Raw warning codes and status registers / not a safety assessment',
          style: const TextStyle(color: muted, fontSize: 10),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: warnings == null
            ? []
            : [
                Text(
                  'Received ${age(battery.warningsAt, now)}. Unknown bit meanings are not decoded.',
                  style: const TextStyle(color: muted, fontSize: 11),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final entry in warnings.registers.entries)
                      _register(entry.key, entry.value),
                  ],
                ),
                const SizedBox(height: 12),
                SelectableText(
                  'Cell warning codes: ${warnings.cells.isEmpty ? 'not provided' : warnings.cells.map((code) => '0x${hexByte(code)}').join(', ')}',
                  style: const TextStyle(color: muted, fontSize: 11),
                ),
                const SizedBox(height: 6),
                SelectableText(
                  'Temperature warning codes: ${warnings.temperatures.isEmpty ? 'not provided' : warnings.temperatures.map((code) => '0x${hexByte(code)}').join(', ')}',
                  style: const TextStyle(color: muted, fontSize: 11),
                ),
              ],
      ),
    );
  }

  Widget _register(String name, int code) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.04),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      '$name  0x${hexByte(code)}',
      style: TextStyle(fontSize: 11, color: code == 0 ? muted : sky),
    ),
  );
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child, this.padding = 22});
  final Widget child;
  final double padding;

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.all(padding),
    decoration: BoxDecoration(
      color: panelColor,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
    ),
    child: child,
  );
}

class _Badge extends StatelessWidget {
  const _Badge({
    required this.label,
    required this.color,
    required this.icon,
    this.small = false,
  });
  final String label;
  final Color color;
  final IconData icon;
  final bool small;

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.symmetric(
      horizontal: small ? 10 : 14,
      vertical: small ? 7 : 10,
    ),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(30),
      border: Border.all(color: color.withValues(alpha: 0.17)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: small ? 6 : 14),
        const SizedBox(width: 7),
        Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: small ? 9 : 10,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.6,
          ),
        ),
      ],
    ),
  );
}

String age(DateTime? at, DateTime now) {
  if (at == null) return 'no reading';
  final seconds = math.max(0, now.difference(at).inSeconds);
  if (seconds < 2) return 'just now';
  if (seconds < 60) return '${seconds}s ago';
  if (seconds < 3600) return '${seconds ~/ 60}m ago';
  return '${seconds ~/ 3600}h ago';
}

String _time(DateTime at) =>
    '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}:${at.second.toString().padLeft(2, '0')}';

String _visible(String text) => text.replaceAllMapped(
  RegExp(r'[^\x20-\x7e]'),
  (match) => '\\x${hexByte(match[0]!.codeUnitAt(0))}',
);

String _hexField(int? value) =>
    value == null ? 'not provided' : '0x${hexByte(value)}';
