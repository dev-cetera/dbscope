// Chart widgets. [MetaChartCard] loads and shows one ChartSpec;
// [MetaChartPlot] draws already-loaded ChartData with fl_chart. Colours
// come from the theme's AppPalette and the schema viewer's relationship
// palette, so charts follow every theme plugin.

import 'dart:async';
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:schema_viewer/schema_viewer.dart' show kRelationshipPalette;
import 'package:widgets/widgets.dart';

import '../../db/executor.dart';
import '../action_binding.dart';
import '../meta_cache.dart';
import '../meta_models.dart';
import '../ui/action_trust.dart';
import '../ui/meta_dialogs.dart';
import 'chart_data.dart';

/// Tables above this estimated size wait for an explicit "Run" instead of
/// charting on open.
const kAutoRunChartRowLimit = 2000000;

class MetaChartCard extends StatefulWidget {
  const MetaChartCard({
    super.key,
    required this.chart,
    required this.executor,
    this.row = const BindingContext(),
    this.autoRun = true,
    this.height = 220,
  });
  final ChartSpec chart;
  final DbExecutor executor;
  final BindingContext row;

  /// When false, the chart waits for the user to press Run.
  final bool autoRun;
  final double height;

  @override
  State<MetaChartCard> createState() => _MetaChartCardState();
}

class _MetaChartCardState extends State<MetaChartCard> {
  ChartData? _data;
  String? _error;
  var _loading = false;

  @override
  void initState() {
    super.initState();
    if (widget.autoRun) {
      // Defer: _load may open the trust dialog, which needs a built tree.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _autoLoad();
      });
    }
  }

  /// Auto-run never prompts: an untrusted SQL chart waits for a click.
  void _autoLoad() {
    final connectionId = MetadataCache.instance
        .snapshotForExecutor(widget.executor)
        ?.profileId;
    if (_needsTrust && connectionId != null) {
      final snapshot = MetadataCache.instance.snapshotFor(connectionId);
      if (snapshot == null ||
          !MetaTrust.isTrusted(connectionId, snapshot.index, TrustScope.read)) {
        return;
      }
    }
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant MetaChartCard old) {
    super.didUpdateWidget(old);
    if (old.chart.id != widget.chart.id || old.row.row != widget.row.row) {
      _data = null;
      _error = null;
      if (widget.autoRun) _autoLoad();
    }
  }

  /// Charts whose SQL comes from the metadata (query / inline SQL) run
  /// only after the user trusted the connection's metadata SQL.
  bool get _needsTrust => widget.chart.source is! ChartTableSource;

  Future<void> _load() async {
    final connectionId = MetadataCache.instance
        .snapshotForExecutor(widget.executor)
        ?.profileId;
    if (_needsTrust) {
      // Fail closed: metadata SQL with no identifiable connection can't be
      // checked for trust, so it doesn't run.
      if (connectionId == null) {
        setState(() => _error = "This chart's connection has no metadata.");
        return;
      }
      final snapshot = MetadataCache.instance.snapshotFor(connectionId)!;
      if (!MetaTrust.isTrusted(connectionId, snapshot.index, TrustScope.read)) {
        final ok = await ensureTrusted(context, connectionId, TrustScope.read);
        if (!mounted) return;
        if (!ok) {
          setState(() {
            _error = "Trust this connection's metadata SQL to run the chart.";
          });
          return;
        }
      }
    }
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await runChart(
        widget.chart,
        executor: widget.executor,
        row: widget.row,
      );
      if (!mounted) return;
      setState(() {
        _data = data;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    Widget body;
    if (_loading) {
      body = const Center(child: LoadingView());
    } else if (_error != null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            _error!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
            textAlign: TextAlign.center,
          ),
        ),
      );
    } else if (_data == null) {
      body = Center(
        child: TextButton.icon(
          onPressed: _load,
          icon: const Icon(Icons.play_arrow, size: 16),
          label: const Text('Run chart'),
        ),
      );
    } else if (_data!.isEmpty) {
      body = Center(
        child: Text('No data', style: TextStyle(color: palette.mutedText)),
      );
    } else {
      body = Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 12, 8),
        child: MetaChartPlot(type: widget.chart.type, data: _data!),
      );
    }
    return Container(
      height: widget.height,
      decoration: BoxDecoration(
        color: palette.surfaceRaised,
        border: Border.all(color: palette.border),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 4, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.chart.label,
                    style: theme.textTheme.labelLarge,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: 'Refresh chart',
                  visualDensity: VisualDensity.compact,
                  iconSize: 16,
                  icon: const Icon(Icons.refresh),
                  onPressed: _loading ? null : _load,
                ),
              ],
            ),
          ),
          Expanded(child: body),
        ],
      ),
    );
  }
}

Color _seriesColor(int i) =>
    kRelationshipPalette[i % kRelationshipPalette.length];

class MetaChartPlot extends StatelessWidget {
  const MetaChartPlot({super.key, required this.type, required this.data});
  final ChartType type;
  final ChartData data;

  @override
  Widget build(BuildContext context) {
    switch (type) {
      case ChartType.stat:
        return _StatPlot(data: data);
      case ChartType.pie:
        return _PiePlot(data: data);
      case ChartType.scatter:
        return _ScatterPlot(data: data);
      case ChartType.line:
      case ChartType.area:
        return _LinePlot(data: data, filled: type == ChartType.area);
      case ChartType.bar:
      case ChartType.histogram:
        return _BarPlot(data: data, stacked: false);
      case ChartType.stackedBar:
        return _BarPlot(data: data, stacked: true);
    }
  }
}

String _compact(double v) {
  final a = v.abs();
  if (a >= 1e9) return '${(v / 1e9).toStringAsFixed(1)}B';
  if (a >= 1e6) return '${(v / 1e6).toStringAsFixed(1)}M';
  if (a >= 1e3) return '${(v / 1e3).toStringAsFixed(1)}K';
  if (v == v.roundToDouble()) return v.toStringAsFixed(0);
  return v.toStringAsFixed(2);
}

FlTitlesData _titles(BuildContext context, List<String> xLabels) {
  final style = TextStyle(
    fontSize: 10,
    color: AppPalette.of(context).mutedText,
  );
  final every = math.max(1, (xLabels.length / 8).ceil());
  return FlTitlesData(
    topTitles: const AxisTitles(),
    rightTitles: const AxisTitles(),
    leftTitles: AxisTitles(
      sideTitles: SideTitles(
        showTitles: true,
        reservedSize: 40,
        getTitlesWidget: (value, meta) => SideTitleWidget(
          meta: meta,
          child: Text(_compact(value), style: style),
        ),
      ),
    ),
    bottomTitles: AxisTitles(
      sideTitles: SideTitles(
        showTitles: true,
        interval: 1,
        getTitlesWidget: (value, meta) {
          final i = value.round();
          if (i < 0 || i >= xLabels.length || i % every != 0) {
            return const SizedBox.shrink();
          }
          final label = xLabels[i];
          return SideTitleWidget(
            meta: meta,
            child: Text(
              label.length > 12 ? '${label.substring(0, 11)}…' : label,
              style: style,
            ),
          );
        },
      ),
    ),
  );
}

FlGridData _grid(BuildContext context) => FlGridData(
  drawVerticalLine: false,
  getDrawingHorizontalLine: (_) => FlLine(
    color: AppPalette.of(context).border.withValues(alpha: 0.5),
    strokeWidth: 0.5,
  ),
);

class _Legend extends StatelessWidget {
  const _Legend({required this.series});
  final List<ChartSeriesData> series;

  @override
  Widget build(BuildContext context) {
    if (series.length < 2) return const SizedBox.shrink();
    return Wrap(
      spacing: 10,
      children: [
        for (var i = 0; i < series.length && i < 12; i++)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 8, height: 8, color: _seriesColor(i)),
              const SizedBox(width: 4),
              Text(series[i].name, style: const TextStyle(fontSize: 10)),
            ],
          ),
      ],
    );
  }
}

class _LinePlot extends StatelessWidget {
  const _LinePlot({required this.data, required this.filled});
  final ChartData data;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final bars = <LineChartBarData>[];
    for (var s = 0; s < data.series.length; s++) {
      final color = _seriesColor(s);
      final values = data.series[s].values;
      bars.add(
        LineChartBarData(
          spots: [
            for (var i = 0; i < values.length; i++)
              if (values[i] != null) FlSpot(i.toDouble(), values[i]!),
          ],
          color: color,
          dotData: FlDotData(show: values.length <= 40),
          belowBarData: BarAreaData(
            show: filled,
            color: color.withValues(alpha: 0.18),
          ),
        ),
      );
    }
    return Column(
      children: [
        Expanded(
          child: LineChart(
            LineChartData(
              lineBarsData: bars,
              titlesData: _titles(context, data.xLabels),
              gridData: _grid(context),
              borderData: FlBorderData(show: false),
            ),
          ),
        ),
        _Legend(series: data.series),
      ],
    );
  }
}

class _BarPlot extends StatelessWidget {
  const _BarPlot({required this.data, required this.stacked});
  final ChartData data;
  final bool stacked;

  @override
  Widget build(BuildContext context) {
    final groups = <BarChartGroupData>[];
    final count = data.xLabels.length;
    final width = math.max(2.0, math.min(18.0, 360 / math.max(1, count)));
    for (var i = 0; i < count; i++) {
      if (stacked) {
        var acc = 0.0;
        final items = <BarChartRodStackItem>[];
        for (var s = 0; s < data.series.length; s++) {
          final v = data.series[s].values[i] ?? 0;
          items.add(BarChartRodStackItem(acc, acc + v, _seriesColor(s)));
          acc += v;
        }
        groups.add(
          BarChartGroupData(
            x: i,
            barRods: [
              BarChartRodData(
                toY: acc,
                width: width,
                rodStackItems: items,
                color: Colors.transparent,
                borderRadius: BorderRadius.zero,
              ),
            ],
          ),
        );
      } else {
        groups.add(
          BarChartGroupData(
            x: i,
            barRods: [
              for (var s = 0; s < data.series.length; s++)
                BarChartRodData(
                  toY: data.series[s].values[i] ?? 0,
                  width: width / math.max(1, data.series.length),
                  color: _seriesColor(s),
                  borderRadius: BorderRadius.zero,
                ),
            ],
          ),
        );
      }
    }
    return Column(
      children: [
        Expanded(
          child: BarChart(
            BarChartData(
              barGroups: groups,
              titlesData: _titles(context, data.xLabels),
              gridData: _grid(context),
              borderData: FlBorderData(show: false),
              barTouchData: BarTouchData(
                touchTooltipData: BarTouchTooltipData(
                  getTooltipItem: (group, groupIndex, rod, rodIndex) =>
                      BarTooltipItem(
                        '${data.xLabels[group.x]}\n${_compact(rod.toY)}',
                        const TextStyle(fontSize: 11, color: Colors.white),
                      ),
                ),
              ),
            ),
          ),
        ),
        _Legend(series: data.series),
      ],
    );
  }
}

class _PiePlot extends StatelessWidget {
  const _PiePlot({required this.data});
  final ChartData data;

  @override
  Widget build(BuildContext context) {
    final values = data.series.isEmpty
        ? const <double?>[]
        : data.series.first.values;
    final total = values.fold<double>(0, (a, b) => a + (b ?? 0));
    final sections = <PieChartSectionData>[];
    for (var i = 0; i < values.length && i < 24; i++) {
      final v = values[i] ?? 0;
      if (v <= 0) continue;
      final share = total == 0 ? 0 : v / total * 100;
      sections.add(
        PieChartSectionData(
          value: v,
          color: _seriesColor(i),
          radius: 70,
          title: share >= 6 ? '${share.toStringAsFixed(0)}%' : '',
          titleStyle: const TextStyle(fontSize: 10, color: Colors.white),
        ),
      );
    }
    return Row(
      children: [
        Expanded(
          child: PieChart(
            PieChartData(sections: sections, sectionsSpace: 1),
          ),
        ),
        SizedBox(
          width: 140,
          child: ListView(
            children: [
              for (var i = 0; i < data.xLabels.length && i < 24; i++)
                Row(
                  children: [
                    Container(width: 8, height: 8, color: _seriesColor(i)),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        '${data.xLabels[i]} (${_compact(values[i] ?? 0)})',
                        style: const TextStyle(fontSize: 10),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ScatterPlot extends StatelessWidget {
  const _ScatterPlot({required this.data});
  final ChartData data;

  @override
  Widget build(BuildContext context) {
    final xs = data.xNumbers;
    final spots = <ScatterSpot>[];
    for (var s = 0; s < data.series.length; s++) {
      final values = data.series[s].values;
      for (var i = 0; i < values.length; i++) {
        final y = values[i];
        if (y == null) continue;
        spots.add(
          ScatterSpot(
            xs == null ? i.toDouble() : xs[i],
            y,
            dotPainter: FlDotCirclePainter(radius: 3, color: _seriesColor(s)),
          ),
        );
      }
    }
    return ScatterChart(
      ScatterChartData(
        scatterSpots: spots,
        gridData: _grid(context),
        borderData: FlBorderData(show: false),
        titlesData: xs == null
            ? _titles(context, data.xLabels)
            : const FlTitlesData(
                topTitles: AxisTitles(),
                rightTitles: AxisTitles(),
              ),
      ),
    );
  }
}

class _StatPlot extends StatelessWidget {
  const _StatPlot({required this.data});
  final ChartData data;

  @override
  Widget build(BuildContext context) {
    final value = data.stat;
    return Center(
      child: Text(
        value == null ? '—' : _compact(value),
        style: Theme.of(context).textTheme.displaySmall,
      ),
    );
  }
}
