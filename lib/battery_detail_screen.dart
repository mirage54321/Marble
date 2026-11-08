import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'battery_screen.dart';
import 'tap_cursor.dart';

const String _kBase = 'https://ridgeboticsapp.onrender.com';

class _Reading {
  final DateTime at;
  final double volts;
  const _Reading(this.at, this.volts);
}

class _Match {
  final String name;
  final DateTime at;
  final double? minVolts;
  final double? secondsBelow8;
  final double? brownouts;
  final double? ampHours;
  final double? resistance;

  const _Match({
    required this.name,
    required this.at,
    this.minVolts,
    this.secondsBelow8,
    this.brownouts,
    this.ampHours,
    this.resistance,
  });

  factory _Match.fromJson(Map<String, dynamic> j) => _Match(
        name: j['matchName'] as String? ?? 'Practice',
        at: DateTime.tryParse(j['enabledStartAt'] as String? ?? '') ??
            DateTime.tryParse(j['createdAt'] as String? ?? '') ??
            DateTime.now(),
        minVolts: (j['minimumVoltage'] as num?)?.toDouble(),
        secondsBelow8: (j['secondsBelow8Volts'] as num?)?.toDouble(),
        brownouts: (j['brownoutCount'] as num?)?.toDouble(),
        ampHours: (j['ampHoursUsed'] as num?)?.toDouble(),
        resistance: (j['internalResistanceMilliohms'] as num?)?.toDouble(),
      );
}

// What /battery/health says about one battery. Rough for now: the checks below
// are built from it, so a better model can replace the backend logic later
// without touching this screen.
class _Health {
  final String status; // healthy | monitor | avoid | not_enough_data
  final String reason;
  final int matchCount;
  final int brownoutMatches;
  final int lowVoltageMatches;
  final bool resistanceRising;
  final double? latestResistance;

  const _Health({
    required this.status,
    required this.reason,
    required this.matchCount,
    required this.brownoutMatches,
    required this.lowVoltageMatches,
    required this.resistanceRising,
    this.latestResistance,
  });

  factory _Health.fromJson(Map<String, dynamic> j) => _Health(
        status: j['status'] as String? ?? 'not_enough_data',
        reason: j['reason'] as String? ?? '',
        matchCount: (j['matchCount'] as num?)?.toInt() ?? 0,
        brownoutMatches: (j['brownoutMatches'] as num?)?.toInt() ?? 0,
        lowVoltageMatches: (j['lowVoltageMatches'] as num?)?.toInt() ?? 0,
        resistanceRising: j['resistanceRising'] == true,
        latestResistance:
            (j['latestResistanceMilliohms'] as num?)?.toDouble(),
      );
}

class _Check {
  final String status; // good | warn | bad | info
  final String title;
  final String detail;
  const _Check(this.status, this.title, this.detail);
}

/// One battery: its voltage graph, its numbers, and how Marble reads it.
/// Opened by tapping a battery on the Battery tracker.
class BatteryDetailScreen extends StatefulWidget {
  final String label;
  final String team;
  final String? passcode;
  final bool isGuest;
  final bool autoMode;
  final bool showFlags;

  /// Returns the newest copy of this battery (the tracker replaces its list on
  /// every refresh), or null if it no longer exists.
  final Battery? Function() lookup;

  final Future<void> Function(Battery) onRename;
  final Future<void> Function(Battery) onToggleInUse;
  final Future<void> Function(Battery) onToggleCharging;
  final Future<void> Function(Battery) onFlag;

  /// Deletes the battery (or, with dataOnly, just its logs and readings).
  /// Returns true when it worked.
  final Future<bool> Function(Battery, {required bool dataOnly}) onDelete;

  const BatteryDetailScreen({
    super.key,
    required this.label,
    required this.team,
    required this.passcode,
    required this.isGuest,
    required this.autoMode,
    required this.showFlags,
    required this.lookup,
    required this.onRename,
    required this.onToggleInUse,
    required this.onToggleCharging,
    required this.onFlag,
    required this.onDelete,
  });

  @override
  State<BatteryDetailScreen> createState() => _BatteryDetailScreenState();
}

class _BatteryDetailScreenState extends State<BatteryDetailScreen> {
  static const List<List<Object>> _ranges = [
    [1, '1 h'],
    [6, '6 h'],
    [24, '24 h'],
    [168, '7 d'],
  ];

  Timer? _ticker;
  int _hours = 24;

  List<_Reading>? _readings;
  DateTime _readingsAt = DateTime.now();
  String? _readingsError;
  bool _loadingReadings = false;
  int? _hover;

  _Health? _health;
  List<_Match> _matches = [];
  bool _insightsLoaded = false;

  @override
  void initState() {
    super.initState();
    if (!widget.isGuest) {
      _loadReadings();
      _loadInsights();
    }
    // Keeps the node status, voltage and button states fresh while this page is open.
    _ticker = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Map<String, String> get _headers =>
      {'X-Team-Passcode': widget.passcode ?? ''};

  Future<void> _loadReadings() async {
    if (_loadingReadings) return;
    _loadingReadings = true;
    final hours = _hours;
    try {
      final uri = Uri.parse(
          '$_kBase/battery/readings?teamNumber=${Uri.encodeQueryComponent(widget.team)}&hours=$hours');
      final res =
          await http.get(uri, headers: _headers).timeout(const Duration(seconds: 15));
      if (!mounted) return;
      if (res.statusCode != 200) throw StateError('readings ${res.statusCode}');
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final series = (data['series'] as Map<String, dynamic>?) ?? {};
      List<dynamic> raw = [];
      for (final entry in series.entries) {
        if (entry.key.toLowerCase() == widget.label.toLowerCase()) {
          raw = entry.value as List<dynamic>;
        }
      }
      final points = <_Reading>[];
      for (final p in raw) {
        final pair = p as List<dynamic>;
        points.add(_Reading(
          DateTime.fromMillisecondsSinceEpoch((pair[0] as num).toInt()),
          (pair[1] as num).toDouble(),
        ));
      }
      setState(() {
        _readings = points;
        _readingsAt = DateTime.now();
        _readingsError = null;
        _hover = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _readingsError = 'Could not load the graph');
    } finally {
      _loadingReadings = false;
    }
    // The range changed while this one was loading: load the newer one too.
    if (mounted && hours != _hours) _loadReadings();
  }

  Future<void> _loadInsights() async {
    try {
      final team = Uri.encodeQueryComponent(widget.team);
      final results = await Future.wait([
        http
            .get(Uri.parse('$_kBase/battery/health?teamNumber=$team'),
                headers: _headers)
            .timeout(const Duration(seconds: 15)),
        http
            .get(Uri.parse('$_kBase/battery/telemetry?teamNumber=$team'),
                headers: _headers)
            .timeout(const Duration(seconds: 15)),
      ]);
      if (!mounted) return;

      _Health? health;
      if (results[0].statusCode == 200) {
        final list = (jsonDecode(results[0].body)
                as Map<String, dynamic>)['health'] as List<dynamic>? ??
            [];
        for (final h in list) {
          final m = h as Map<String, dynamic>;
          if ((m['label'] as String? ?? '').toLowerCase() ==
              widget.label.toLowerCase()) {
            health = _Health.fromJson(m);
          }
        }
      }

      final matches = <_Match>[];
      if (results[1].statusCode == 200) {
        final list = (jsonDecode(results[1].body)
                as Map<String, dynamic>)['telemetry'] as List<dynamic>? ??
            [];
        for (final t in list) {
          final m = t as Map<String, dynamic>;
          if ((m['label'] as String? ?? '').toLowerCase() ==
              widget.label.toLowerCase()) {
            matches.add(_Match.fromJson(m));
          }
        }
        matches.sort((a, b) => b.at.compareTo(a.at));
      }

      setState(() {
        _health = health;
        _matches = matches;
        _insightsLoaded = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _insightsLoaded = true);
    }
  }

  // ---------- numbers ----------

  double? _median(List<double> v) {
    if (v.isEmpty) return null;
    final s = [...v]..sort();
    final m = s.length ~/ 2;
    return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2;
  }

  List<double> _nums(Iterable<double?> v) => v.whereType<double>().toList();

  String _fmt(double? v, int digits, [String unit = '']) =>
      v == null ? '–' : '${v.toStringAsFixed(digits)}$unit';

  List<_Check> _checks() {
    final h = _health;
    if (h == null || h.matchCount == 0) return [];
    final out = <_Check>[];
    final n = h.matchCount;
    final matchesWord = n == 1 ? 'match' : 'matches';

    if (h.brownoutMatches > 0) {
      out.add(_Check('bad', 'Brownouts',
          'Browned out in ${h.brownoutMatches} of $n $matchesWord.'));
    } else {
      out.add(const _Check(
          'good', 'No brownouts', 'The robot never browned out on this battery.'));
    }

    if (h.lowVoltageMatches > 0) {
      out.add(_Check('warn', 'Voltage dips',
          'Dropped below 8 V in ${h.lowVoltageMatches} of $n $matchesWord.'));
    } else {
      out.add(const _Check('good', 'Voltage held up', 'Never dropped below 8 V.'));
    }

    if (h.resistanceRising) {
      out.add(_Check('warn', 'Resistance is rising',
          'Higher than in earlier matches (${_fmt(h.latestResistance, 1, ' mΩ')} latest).'));
    } else if (h.latestResistance != null) {
      out.add(_Check('good', 'Resistance is steady',
          '${_fmt(h.latestResistance, 1, ' mΩ')} and not climbing.'));
    } else {
      out.add(const _Check('info', 'Resistance',
          'No reading yet. The robot\'s power board has to report current.'));
    }

    final ah = _median(_nums(_matches.map((m) => m.ampHours)));
    if (ah != null) {
      out.add(_Check('info', 'Energy used', 'About ${ah.toStringAsFixed(2)} Ah per match.'));
    }
    if (n < 3) {
      out.add(_Check('info', 'Early days',
          'Only $n $matchesWord so far. This gets more reliable with more.'));
    }
    return out;
  }

  String _summary() {
    final h = _health;
    if (h == null || h.matchCount == 0) return 'Nothing logged for this battery yet.';
    switch (h.status) {
      case 'healthy':
        return 'Looking healthy.';
      case 'monitor':
        return 'Worth keeping an eye on.';
      case 'avoid':
        return 'This battery is struggling. Consider retiring or testing it.';
      default:
        return 'Not enough match logs to say yet.';
    }
  }

  // ---------- build ----------

  @override
  Widget build(BuildContext context) {
    final b = widget.lookup();
    return Scaffold(
      backgroundColor: const Color.fromARGB(255, 255, 255, 248),
      body: SafeArea(
        child: Column(children: [
          _topBar(b),
          Expanded(
            child: b == null
                ? Center(
                    child: Text('This battery is no longer in Marble.',
                        style: TextStyle(color: Colors.grey[600])))
                : ListView(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
                    children: [
                      _header(b),
                      if (!widget.isGuest && !widget.autoMode) ...[
                        const SizedBox(height: 14),
                        _actions(b),
                      ],
                      const SizedBox(height: 22),
                      _voltageSection(),
                      if (!widget.isGuest) ...[
                        const SizedBox(height: 22),
                        _statsSection(),
                        _readsSection(),
                        _matchesSection(),
                      ],
                      if (widget.showFlags && b.flags.isNotEmpty) ...[
                        const SizedBox(height: 22),
                        _flagsSection(b),
                      ],
                    ],
                  ),
          ),
        ]),
      ),
    );
  }

  Widget _topBar(Battery? b) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      child: Row(children: [
        TapCursor(
          onTap: () => Navigator.pop(context),
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
                color: YellorLight, borderRadius: BorderRadius.circular(10)),
            child: const Icon(Icons.arrow_back, color: Yellor, size: 17),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(b?.displayName ?? widget.label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
        ),
      ]),
    );
  }

  Widget _header(Battery b) {
    final connected = b.nodeConnected;
    final age = b.nodeAge;
    final nodeText = connected
        ? 'Node connected · ${b.lastVoltage!.toStringAsFixed(2)} V · ${timeAgoText(age!)}'
        : age != null
            ? 'Not connected · last reading ${timeAgoText(age)}'
            : 'Not connected · no readings yet';
    final tag = batteryStatusLabel(b);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.black.withValues(alpha: 0.07), width: 0.5),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        BatteryIcon(battery: b, height: 84),
        const SizedBox(width: 18),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(b.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w600)),
            if (b.name != null && b.name!.trim().isNotEmpty)
              Text(b.label, style: TextStyle(fontSize: 12, color: Colors.grey[500])),
            const SizedBox(height: 8),
            Row(children: [
              Icon(Icons.circle,
                  size: 9, color: connected ? nodeOnColor : nodeOffColor),
              const SizedBox(width: 6),
              Expanded(
                child: Text(nodeText,
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: connected ? nodeOnColor : Colors.grey[600])),
              ),
            ]),
            if (!widget.autoMode) ...[
              const SizedBox(height: 6),
              Text(tag,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: batteryStatusColor(b))),
              Text(batteryChargedLabel(b),
                  style: TextStyle(fontSize: 12.5, color: Colors.grey[700])),
            ] else if (b.isInUse) ...[
              const SizedBox(height: 6),
              const Text('IN USE',
                  style: TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w700, color: redChar)),
            ],
          ]),
        ),
        if (!widget.isGuest) ...[
          const SizedBox(width: 8),
          TapCursor(
            onTap: () => _showMenu(b),
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                  color: YellorLight, borderRadius: BorderRadius.circular(10)),
              child: const Icon(Icons.settings_outlined, color: Yellor, size: 18),
            ),
          ),
        ],
      ]),
    );
  }

  // The gear on the far right: rename, delete, or cancel.
  void _showMenu(Battery b) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            _menuTile(Icons.edit_outlined, 'Rename', () async {
              Navigator.pop(ctx);
              await widget.onRename(b);
              if (mounted) setState(() {});
            }),
            _menuTile(Icons.close, 'Delete', () {
              Navigator.pop(ctx);
              _confirmDelete(b);
            }, color: redChar),
            const Divider(height: 8),
            _menuTile(null, 'Cancel', () => Navigator.pop(ctx),
                color: Colors.grey[600]),
          ]),
        ),
      ),
    );
  }

  Widget _menuTile(IconData? icon, String label, VoidCallback onTap, {Color? color}) {
    final c = color ?? Colors.black87;
    return TapCursor(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 13),
        child: Row(children: [
          SizedBox(width: 22, child: icon == null ? null : Icon(icon, size: 20, color: c)),
          const SizedBox(width: 14),
          Text(label, style: TextStyle(fontSize: 15, color: c)),
        ]),
      ),
    );
  }

  Future<void> _confirmDelete(Battery b) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${b.displayName}?'),
        content: const Text(
            'Delete battery removes it and everything recorded for it.\n\n'
            'Delete its data keeps the battery but clears its robot logs and voltage readings.\n\n'
            'This can\'t be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'data'),
              child: const Text('Delete its data')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: redChar),
              onPressed: () => Navigator.pop(ctx, 'battery'),
              child: const Text('Delete battery')),
        ],
      ),
    );
    if (choice == null || !mounted) return;

    final dataOnly = choice == 'data';
    final ok = await widget.onDelete(b, dataOnly: dataOnly);
    if (!ok || !mounted) return;
    if (!dataOnly) {
      Navigator.pop(context); // the battery is gone, so leave its page
      return;
    }
    setState(() {
      _readings = null;
      _health = null;
      _matches = [];
      _insightsLoaded = false;
      _hover = null;
    });
    _loadReadings();
    _loadInsights();
  }

  // Manual teams only: the buttons that used to sit on every row.
  Widget _actions(Battery b) {
    final charging = b.isCharging && !b.isDead;
    Widget button(String text, Color bg, Color fg, VoidCallback onTap) =>
        Expanded(
          child: TapCursor(
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 12),
              alignment: Alignment.center,
              decoration:
                  BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
              child: Text(text,
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600, color: fg)),
            ),
          ),
        );

    return Row(children: [
      button(b.isInUse ? 'In use' : 'Use', b.isInUse ? redChar : YellorLight,
          b.isInUse ? Colors.white : YellorDark, () async {
        await widget.onToggleInUse(b);
        if (mounted) setState(() {});
      }),
      const SizedBox(width: 8),
      button(
          charging ? 'Charging' : 'Charge',
          charging
              ? greenChar
              : b.isCoolingDown
                  ? Colors.blueGrey.withValues(alpha: 0.15)
                  : YellorLight,
          charging
              ? Colors.white
              : b.isCoolingDown
                  ? Colors.blueGrey
                  : YellorDark, () async {
        await widget.onToggleCharging(b);
        if (mounted) setState(() {});
      }),
      const SizedBox(width: 8),
      button('Flag weak', YellorLight, YellorDark, () async {
        await widget.onFlag(b);
        if (mounted) setState(() {});
      }),
    ]);
  }

  Widget _section(String title, Widget child, {Widget? trailing}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(
          child: Text(title,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        ),
        if (trailing != null) trailing,
      ]),
      const SizedBox(height: 10),
      child,
    ]);
  }

  // ---------- voltage graph ----------

  Widget _rangeButtons() {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      for (final r in _ranges)
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: TapCursor(
            onTap: () {
              setState(() {
                _hours = r[0] as int;
                _readings = null;
              });
              _loadReadings();
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: _hours == r[0] ? Yellor : Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                    color: _hours == r[0]
                        ? YellorDark
                        : Colors.black.withValues(alpha: 0.1),
                    width: 0.8),
              ),
              child: Text(r[1] as String,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: _hours == r[0] ? Colors.black87 : Colors.grey[600])),
            ),
          ),
        ),
    ]);
  }

  List<_Reading> _visible() {
    final pts = _readings;
    if (pts == null) return [];
    final tMin = _readingsAt.subtract(Duration(hours: _hours));
    return pts.where((p) => !p.at.isBefore(tMin)).toList();
  }

  Widget _voltageSection() {
    Widget body;
    if (widget.isGuest) {
      body = _emptyBox('Log in to the team to see the voltage graph.');
    } else if (_readingsError != null && _readings == null) {
      body = _emptyBox(_readingsError!);
    } else if (_readings == null) {
      body = _emptyBox('Loading…');
    } else {
      final pts = _visible();
      if (pts.isEmpty) {
        body = _emptyBox(
            'No readings in this time range. They appear once this battery\'s node starts sending.');
      } else {
        body = _graph(pts);
      }
    }
    return _section('Voltage', body,
        trailing: widget.isGuest ? null : _rangeButtons());
  }

  Widget _emptyBox(String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 34, horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.black.withValues(alpha: 0.08), width: 0.8),
      ),
      child: Text(text,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: Colors.grey[600])),
    );
  }

  Widget _graph(List<_Reading> pts) {
    final hover = (_hover != null && _hover! < pts.length) ? _hover : null;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.black.withValues(alpha: 0.08), width: 0.8),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: LayoutBuilder(builder: (context, c) {
            final w = c.maxWidth;
            void pick(double dx) {
              setState(() => _hover = _GraphPainter.nearest(
                  pts, dx, w, _readingsAt, _hours));
            }

            return GestureDetector(
              onTapDown: (d) => pick(d.localPosition.dx),
              onHorizontalDragUpdate: (d) => pick(d.localPosition.dx),
              child: CustomPaint(
                size: Size(w, 210),
                painter: _GraphPainter(
                    points: pts, now: _readingsAt, hours: _hours, hover: hover),
              ),
            );
          }),
        ),
      ),
      const SizedBox(height: 6),
      Text(
          hover != null
              ? '${pts[hover].volts.toStringAsFixed(2)} V · ${_clock(pts[hover].at)}'
              : 'Touch the graph to see exact values',
          style: TextStyle(
              fontSize: 12,
              fontWeight: hover != null ? FontWeight.w600 : FontWeight.w400,
              color: Colors.grey[600])),
    ]);
  }

  String _clock(DateTime t) {
    final l = t.toLocal();
    final h12 = l.hour % 12 == 0 ? 12 : l.hour % 12;
    final mm = l.minute.toString().padLeft(2, '0');
    final ap = l.hour >= 12 ? 'PM' : 'AM';
    final day = _hours > 24 ? '${l.month}/${l.day} ' : '';
    return '$day$h12:$mm $ap';
  }

  // ---------- numbers + analysis ----------

  Widget _statsSection() {
    if (_matches.isEmpty) return const SizedBox.shrink();
    final res = _median(_nums(_matches.map((m) => m.resistance)));
    final ah = _nums(_matches.map((m) => m.ampHours));
    final mv = _nums(_matches.map((m) => m.minVolts));
    final brown = _nums(_matches.map((m) => m.brownouts)).fold<double>(0, (a, b) => a + b);
    final below8 =
        _nums(_matches.map((m) => m.secondsBelow8)).fold<double>(0, (a, b) => a + b);
    final stats = <List<String>>[
      ['Resistance', _fmt(res, 1, ' mΩ')],
      ['Lowest voltage', _fmt(mv.isEmpty ? null : mv.reduce((a, b) => a < b ? a : b), 2, ' V')],
      ['Avg amp-hours', _fmt(ah.isEmpty ? null : ah.reduce((a, b) => a + b) / ah.length, 2, ' Ah')],
      ['Brownouts', brown.toStringAsFixed(0)],
      ['Below 8 V', _fmt(below8, 1, ' s')],
      ['Matches', '${_matches.length}'],
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: LayoutBuilder(builder: (context, c) {
        const gap = 8.0;
        final w = (c.maxWidth - gap * 2) / 3;
        return Wrap(spacing: gap, runSpacing: gap, children: [
          for (final s in stats)
            Container(
              width: w,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              decoration: BoxDecoration(
                  color: YellorLight, borderRadius: BorderRadius.circular(12)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(s[1],
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                ),
                const SizedBox(height: 2),
                Text(s[0], style: TextStyle(fontSize: 11.5, color: Colors.grey[600])),
              ]),
            ),
        ]);
      }),
    );
  }

  Color _checkColor(String status) {
    switch (status) {
      case 'good':
        return greenChar;
      case 'warn':
        return Colors.orange;
      case 'bad':
        return redChar;
      default:
        return grayChar;
    }
  }

  String _checkMark(String status) {
    switch (status) {
      case 'good':
        return '✓';
      case 'warn':
        return '!';
      case 'bad':
        return '✕';
      default:
        return '•';
    }
  }

  Widget _readsSection() {
    if (!_insightsLoaded) return const SizedBox.shrink();
    final checks = _checks();
    final n = _health?.matchCount ?? 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: _section(
        'How Marble reads this battery',
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_summary(),
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          if (checks.isNotEmpty) const SizedBox(height: 8),
          for (final c in checks)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(
                  width: 22,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _checkColor(c.status).withValues(alpha: 0.16),
                    shape: BoxShape.circle,
                  ),
                  child: Text(_checkMark(c.status),
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: _checkColor(c.status))),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(c.title,
                        style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                    Text(c.detail,
                        style: TextStyle(fontSize: 12.5, color: Colors.grey[600])),
                  ]),
                ),
              ]),
            ),
          const SizedBox(height: 6),
          Text(
              '${n == 0 ? 'No robot logs yet' : 'Based on $n robot log${n == 1 ? '' : 's'}'}. '
              'This overview is a first draft and will get more detailed.',
              style: TextStyle(fontSize: 11.5, color: Colors.grey[500])),
        ]),
      ),
    );
  }

  Widget _matchesSection() {
    if (_matches.isEmpty) return const SizedBox.shrink();
    final shown = _matches.take(5).toList();
    return _section(
      'Recent matches',
      Column(children: [
        for (final m in shown)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 9),
            decoration: BoxDecoration(
              border: Border(
                  top: BorderSide(
                      color: Colors.black.withValues(
                          alpha: identical(m, shown.first) ? 0.0 : 0.07))),
            ),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(m.name,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  Text(timeAgoText(DateTime.now().difference(m.at)),
                      style: TextStyle(fontSize: 12, color: Colors.grey[500])),
                ]),
              ),
              Text(
                  [
                    _fmt(m.minVolts, 1, ' V'),
                    _fmt(m.resistance, 1, ' mΩ'),
                    _fmt(m.ampHours, 2, ' Ah'),
                  ].join(' · '),
                  style: TextStyle(fontSize: 12, color: Colors.grey[600])),
            ]),
          ),
      ]),
    );
  }

  Widget _flagsSection(Battery b) {
    return _section(
      'Flags',
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final f in b.flags.reversed)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(f.note.isEmpty ? 'No reason provided' : f.note,
                  style: const TextStyle(fontSize: 13.5)),
              Text(timeAgoText(DateTime.now().difference(f.flaggedAt)),
                  style: TextStyle(fontSize: 11, color: Colors.grey[500])),
            ]),
          ),
      ]),
    );
  }
}

// Draws one battery's voltage line, like a scope. Gaps in the data (node off,
// out of range) break the line instead of joining across them.
class _GraphPainter extends CustomPainter {
  final List<_Reading> points;
  final DateTime now;
  final int hours;
  final int? hover;

  _GraphPainter({
    required this.points,
    required this.now,
    required this.hours,
    required this.hover,
  });

  static const double _l = 40, _r = 12, _t = 12, _b = 24;

  static int? nearest(
      List<_Reading> pts, double dx, double width, DateTime now, int hours) {
    if (pts.isEmpty) return null;
    final span = Duration(hours: hours).inMilliseconds.toDouble();
    final tMin = now.millisecondsSinceEpoch - span;
    final frac = ((dx - _l) / (width - _l - _r)).clamp(0.0, 1.0);
    final tHover = tMin + frac * span;
    var best = 0;
    var bestDiff = double.infinity;
    for (var i = 0; i < pts.length; i++) {
      final diff = (pts[i].at.millisecondsSinceEpoch - tHover).abs();
      if (diff < bestDiff) {
        bestDiff = diff;
        best = i;
      }
    }
    return best;
  }

  void _text(Canvas canvas, String text, Offset at,
      {TextAlign align = TextAlign.left, Color color = const Color(0xFF6E6647)}) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: TextStyle(fontSize: 10.5, color: color)),
      textDirection: TextDirection.ltr,
    )..layout();
    var dx = at.dx;
    if (align == TextAlign.right) dx -= tp.width;
    if (align == TextAlign.center) dx -= tp.width / 2;
    tp.paint(canvas, Offset(dx, at.dy - tp.height / 2));
  }

  String _tick(DateTime t) {
    final l = t.toLocal();
    if (hours > 24) return '${l.month}/${l.day}';
    final h12 = l.hour % 12 == 0 ? 12 : l.hour % 12;
    return '$h12:${l.minute.toString().padLeft(2, '0')}';
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final span = Duration(hours: hours).inMilliseconds.toDouble();
    final tMin = now.millisecondsSinceEpoch - span;

    var lo = double.infinity, hi = -double.infinity;
    for (final p in points) {
      if (p.volts < lo) lo = p.volts;
      if (p.volts > hi) hi = p.volts;
    }
    lo = (lo - 0.2).floorToDouble();
    hi = (hi + 0.2).ceilToDouble();
    if (hi - lo < 2) hi = lo + 2;

    double x(DateTime t) =>
        _l + ((t.millisecondsSinceEpoch - tMin) / span) * (w - _l - _r);
    double y(double v) => _t + (1 - (v - lo) / (hi - lo)) * (h - _t - _b);

    final grid = Paint()
      ..color = const Color(0xFFECE6CC)
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final v = lo + (hi - lo) * i / 4;
      final yy = y(v);
      canvas.drawLine(Offset(_l, yy), Offset(w - _r, yy), grid);
      _text(canvas, v.toStringAsFixed(1), Offset(_l - 6, yy), align: TextAlign.right);
    }
    for (var i = 0; i <= 4; i++) {
      final t = DateTime.fromMillisecondsSinceEpoch((tMin + span * i / 4).round());
      _text(canvas, _tick(t), Offset(x(t), h - _b + 12),
          align: i == 0
              ? TextAlign.left
              : i == 4
                  ? TextAlign.right
                  : TextAlign.center);
    }

    final gap = (span / 200) > 300000 ? span / 200 : 300000.0; // at least 5 min
    final line = Paint()
      ..color = nodeOnColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeJoin = StrokeJoin.round;
    final path = Path();
    DateTime? prev;
    for (final p in points) {
      final pt = Offset(x(p.at), y(p.volts));
      if (prev == null || p.at.difference(prev).inMilliseconds > gap) {
        path.moveTo(pt.dx, pt.dy);
      } else {
        path.lineTo(pt.dx, pt.dy);
      }
      prev = p.at;
    }
    canvas.drawPath(path, line);

    final dot = Paint()..color = nodeOnColor;
    if (points.length <= 120) {
      for (final p in points) {
        canvas.drawCircle(Offset(x(p.at), y(p.volts)), 2.5, dot);
      }
    }

    if (hover != null && hover! < points.length) {
      final p = points[hover!];
      final px = x(p.at);
      canvas.drawLine(
          Offset(px, _t),
          Offset(px, h - _b),
          Paint()
            ..color = const Color(0xFF2B2410)
            ..strokeWidth = 1);
      canvas.drawCircle(Offset(px, y(p.volts)), 4.5, dot);
    }
  }

  @override
  bool shouldRepaint(covariant _GraphPainter old) =>
      old.points != points || old.hover != hover || old.hours != hours || old.now != now;
}
