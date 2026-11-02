import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'battery_connection.dart';

const mint = Color(0xFF53E0B6);
const sky = Color(0xFF6ACAF7);
const violet = Color(0xFFB6A1FF);
const amber = Color(0xFFFFC46B);
const canvasColor = Color(0xFF0B121C);
const panelColor = Color(0xFF121E2C);
const muted = Color(0xFF8DA3B8);

class SocGauge extends StatelessWidget {
  const SocGauge({super.key, required this.value});
  final double? value;

  @override
  Widget build(BuildContext context) {
    final percent = value;
    return Semantics(
      label: percent == null
          ? 'State of charge unavailable'
          : 'Calculated state of charge ${percent.toStringAsFixed(1)} percent',
      child: SizedBox(
        width: 116,
        height: 116,
        child: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: 106,
              height: 106,
              child: CircularProgressIndicator(
                value: percent == null ? 0 : (percent / 100).clamp(0, 1),
                strokeWidth: 8,
                strokeCap: StrokeCap.round,
                backgroundColor: Colors.white.withValues(alpha: 0.07),
                color: mint,
              ),
            ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  percent == null ? '--' : '${percent.toStringAsFixed(1)}%',
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Text(
                  'CALC. SOC',
                  style: TextStyle(
                    color: muted,
                    fontSize: 10,
                    letterSpacing: 1.1,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class CellVoltageChart extends StatelessWidget {
  const CellVoltageChart({
    super.key,
    required this.values,
    required this.warningCodes,
  });
  final List<double> values;
  final List<int> warningCodes;

  @override
  Widget build(BuildContext context) {
    final low = values.reduce(math.min);
    final high = values.reduce(math.max);
    final floor = (low * 100).floor() / 100 - 0.01;
    final ceiling = (high * 100).ceil() / 100 + 0.01;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.view_week_rounded, color: sky, size: 19),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'Cell voltages',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            Text(
              '${values.length} CELLS',
              style: const TextStyle(
                color: muted,
                fontSize: 11,
                letterSpacing: 1,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Detail scale ${floor.toStringAsFixed(2)} - ${ceiling.toStringAsFixed(2)} V',
          style: const TextStyle(color: muted, fontSize: 11),
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 150,
          child: Semantics(
            label:
                'Cell voltage bar chart. Minimum ${low.toStringAsFixed(3)}, maximum ${high.toStringAsFixed(3)} volts.',
            child: CustomPaint(
              painter: _CellsPainter(values, warningCodes, floor, ceiling),
              child: const SizedBox.expand(),
            ),
          ),
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = math.max(1, (constraints.maxWidth / 88).floor());
            final width = (constraints.maxWidth - (columns - 1) * 6) / columns;
            return Wrap(
              spacing: 6,
              runSpacing: 6,
              children: List.generate(values.length, (index) {
                final code = index < warningCodes.length
                    ? warningCodes[index]
                    : null;
                final value = values[index];
                final color = code != null && code != 0
                    ? amber
                    : value == low
                    ? sky
                    : value == high
                    ? violet
                    : mint;
                return Tooltip(
                  message:
                      'Cell ${index + 1}: ${value.toStringAsFixed(3)} V; warning ${code == null ? 'unknown' : '0x${code.toRadixString(16).padLeft(2, '0')}'}',
                  child: Container(
                    width: width,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 9,
                    ),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(color: color.withValues(alpha: 0.14)),
                    ),
                    child: Column(
                      children: [
                        Text(
                          'CELL ${(index + 1).toString().padLeft(2, '0')}',
                          style: const TextStyle(
                            color: muted,
                            fontSize: 9,
                            letterSpacing: 0.6,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          value.toStringAsFixed(3),
                          style: TextStyle(
                            color: color,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (code != null && code != 0)
                          Text(
                            'WARN 0x${code.toRadixString(16)}',
                            style: const TextStyle(color: amber, fontSize: 9),
                          ),
                      ],
                    ),
                  ),
                );
              }),
            );
          },
        ),
        const SizedBox(height: 10),
        const Wrap(
          spacing: 16,
          runSpacing: 4,
          children: [
            Text('Min cell', style: TextStyle(color: sky, fontSize: 11)),
            Text('Max cell', style: TextStyle(color: violet, fontSize: 11)),
            Text('Warning flag', style: TextStyle(color: amber, fontSize: 11)),
          ],
        ),
      ],
    );
  }
}

class _CellsPainter extends CustomPainter {
  _CellsPainter(this.values, this.warnings, this.floor, this.ceiling);
  final List<double> values;
  final List<int> warnings;
  final double floor;
  final double ceiling;

  @override
  void paint(Canvas canvas, Size size) {
    final chartHeight = size.height - 20;
    final paint = Paint()..color = Colors.white.withValues(alpha: 0.06);
    for (var i = 0; i <= 3; i++) {
      final y = chartHeight * i / 3;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
    final slot = size.width / values.length;
    final low = values.reduce(math.min);
    final high = values.reduce(math.max);
    for (var i = 0; i < values.length; i++) {
      final height =
          ((values[i] - floor) / (ceiling - floor)).clamp(0, 1) * chartHeight;
      final rect = Rect.fromLTWH(
        i * slot + slot * 0.17,
        chartHeight - height,
        slot * 0.66,
        height,
      );
      final color = i < warnings.length && warnings[i] != 0
          ? amber
          : values[i] == low
          ? sky
          : values[i] == high
          ? violet
          : mint;
      final bar = Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color, color.withValues(alpha: 0.2)],
        ).createShader(rect);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(4)),
        bar,
      );
      final label = TextPainter(
        text: TextSpan(
          text: '${i + 1}',
          style: const TextStyle(color: muted, fontSize: 9),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(
        canvas,
        Offset(i * slot + (slot - label.width) / 2, chartHeight + 6),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CellsPainter old) =>
      old.values != values ||
      old.warnings != warnings ||
      old.floor != floor ||
      old.ceiling != ceiling;
}

class TemperatureChart extends StatelessWidget {
  const TemperatureChart({
    super.key,
    required this.values,
    required this.warningCodes,
  });
  final List<double> values;
  final List<int> warningCodes;

  @override
  Widget build(BuildContext context) {
    if (values.isEmpty) {
      return const Text(
        'No temperature sensors reported',
        style: TextStyle(color: muted),
      );
    }
    final minimum = math.min(-10.0, values.reduce(math.min) - 5);
    final maximum = math.max(60.0, values.reduce(math.max) + 5);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.thermostat_rounded, color: violet, size: 19),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'Temperatures',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            Text(
              '${values.length} SENSORS',
              style: const TextStyle(
                color: muted,
                fontSize: 11,
                letterSpacing: 1,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          'Sensor roles are not identified by the protocol.',
          style: TextStyle(color: muted, fontSize: 11),
        ),
        const SizedBox(height: 16),
        ...List.generate(values.length, (index) {
          final code = index < warningCodes.length ? warningCodes[index] : null;
          final color = code != null && code != 0 ? amber : violet;
          return Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Row(
              children: [
                SizedBox(
                  width: 74,
                  child: Text(
                    'Sensor ${index + 1}',
                    style: const TextStyle(color: muted, fontSize: 12),
                  ),
                ),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: LinearProgressIndicator(
                      value: ((values[index] - minimum) / (maximum - minimum))
                          .clamp(0, 1),
                      minHeight: 8,
                      color: color,
                      backgroundColor: color.withValues(alpha: 0.09),
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                SizedBox(
                  width: 62,
                  child: Text(
                    '${values[index].toStringAsFixed(1)} C',
                    textAlign: TextAlign.end,
                    style: TextStyle(
                      color: color,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ),
                if (code != null && code != 0)
                  Tooltip(
                    message: 'Warning code 0x${code.toRadixString(16)}',
                    child: const Padding(
                      padding: EdgeInsets.only(left: 6),
                      child: Icon(
                        Icons.warning_amber_rounded,
                        size: 16,
                        color: amber,
                      ),
                    ),
                  ),
              ],
            ),
          );
        }),
        Text(
          'Visual range ${minimum.toStringAsFixed(0)} to ${maximum.toStringAsFixed(0)} C; not alarm limits.',
          style: const TextStyle(color: muted, fontSize: 10),
        ),
      ],
    );
  }
}

class VoltageTrend extends StatelessWidget {
  const VoltageTrend({super.key, required this.samples});
  final List<VoltageSample> samples;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.show_chart_rounded, color: mint, size: 19),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'Pack voltage trend',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            Text(
              '${samples.length}/120',
              style: const TextStyle(color: muted, fontSize: 11),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (samples.length < 2)
          const SizedBox(
            height: 70,
            child: Center(
              child: Text(
                'Waiting for more samples',
                style: TextStyle(color: muted, fontSize: 12),
              ),
            ),
          )
        else ...[
          SizedBox(
            height: 70,
            child: CustomPaint(
              painter: _TrendPainter(samples),
              child: const SizedBox.expand(),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '${samples.map((s) => s.voltage).reduce(math.min).toStringAsFixed(3)} - '
            '${samples.map((s) => s.voltage).reduce(math.max).toStringAsFixed(3)} V / '
            '${samples.last.at.difference(samples.first.at).inSeconds}s window',
            style: const TextStyle(color: muted, fontSize: 10),
          ),
        ],
      ],
    );
  }
}

class _TrendPainter extends CustomPainter {
  _TrendPainter(this.samples);
  final List<VoltageSample> samples;

  @override
  void paint(Canvas canvas, Size size) {
    final low = samples.map((s) => s.voltage).reduce(math.min);
    final high = samples.map((s) => s.voltage).reduce(math.max);
    final range = math.max(0.002, high - low);
    final center = (high + low) / 2;
    final start = samples.first.at;
    final span = math.max(1, samples.last.at.difference(start).inMicroseconds);
    final path = Path();
    for (var i = 0; i < samples.length; i++) {
      final x =
          samples[i].at.difference(start).inMicroseconds / span * size.width;
      final y =
          size.height * (0.5 - (samples[i].voltage - center) / range * 0.8);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    final area = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      area,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [mint.withValues(alpha: 0.2), mint.withValues(alpha: 0)],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = mint
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _TrendPainter old) => true;
}
