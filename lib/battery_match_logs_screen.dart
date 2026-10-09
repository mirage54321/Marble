import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'batteryLOGIN_screen.dart';

const _apiBase = 'https://ridgeboticsapp.onrender.com';
const _toolColor = Color(0xFF546E7A);

class _BatteryOption {
  const _BatteryOption(this.label);
  final String label;
}

class _TelemetryRecord {
  const _TelemetryRecord({
    required this.label,
    required this.matchName,
    required this.createdAt,
    this.minimumVoltage,
    this.secondsBelow8Volts,
    this.brownoutCount,
    this.ampHoursUsed,
    this.internalResistanceMilliohms,
  });

  final String label;
  final String matchName;
  final DateTime createdAt;
  final double? minimumVoltage;
  final double? secondsBelow8Volts;
  final double? brownoutCount;
  final double? ampHoursUsed;
  final double? internalResistanceMilliohms;

  factory _TelemetryRecord.fromJson(Map<String, dynamic> json) =>
      _TelemetryRecord(
        label: json['label'] as String? ?? '',
        matchName: json['matchName'] as String? ?? 'Practice',
        createdAt:
            DateTime.tryParse(json['createdAt'] as String? ?? '') ??
            DateTime.now(),
        minimumVoltage: (json['minimumVoltage'] as num?)?.toDouble(),
        secondsBelow8Volts: (json['secondsBelow8Volts'] as num?)?.toDouble(),
        brownoutCount: (json['brownoutCount'] as num?)?.toDouble(),
        ampHoursUsed: (json['ampHoursUsed'] as num?)?.toDouble(),
        internalResistanceMilliohms:
            (json['internalResistanceMilliohms'] as num?)?.toDouble(),
      );
}

class BatteryMatchLogsScreen extends StatefulWidget {
  const BatteryMatchLogsScreen({super.key});

  @override
  State<BatteryMatchLogsScreen> createState() => _BatteryMatchLogsScreenState();
}

class _BatteryMatchLogsScreenState extends State<BatteryMatchLogsScreen> {
  final _match = TextEditingController();
  final _minimumVoltage = TextEditingController();
  final _secondsBelow8 = TextEditingController();
  final _brownouts = TextEditingController();
  final _ampHours = TextEditingController();
  final _resistance = TextEditingController();

  String? _teamNumber;
  String? _passcode;
  String? _selectedBattery;
  List<_BatteryOption> _batteries = [];
  List<_TelemetryRecord> _records = [];
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _match.dispose();
    _minimumVoltage.dispose();
    _secondsBelow8.dispose();
    _brownouts.dispose();
    _ampHours.dispose();
    _resistance.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final prefs = await SharedPreferences.getInstance();
    final team = prefs.getString('battery_team');
    final passcode = prefs.getString('battery_passcode');
    if (team == null || passcode == null) {
      if (mounted) {
        setState(() {
          _teamNumber = null;
          _loading = false;
        });
      }
      return;
    }
    try {
      final batteriesResponse = await http
          .get(
            Uri.parse(
              '$_apiBase/battery/list?teamNumber=$team&passcode=$passcode',
            ),
          )
          .timeout(const Duration(seconds: 15));
      final telemetryResponse = await http
          .get(
            Uri.parse(
              '$_apiBase/battery/telemetry?teamNumber=$team&passcode=$passcode',
            ),
          )
          .timeout(const Duration(seconds: 15));
      if (batteriesResponse.statusCode != 200 ||
          telemetryResponse.statusCode != 200) {
        throw StateError('Could not load battery data');
      }
      final batteryJson =
          jsonDecode(batteriesResponse.body) as Map<String, dynamic>;
      final telemetryJson =
          jsonDecode(telemetryResponse.body) as Map<String, dynamic>;
      final batteries = (batteryJson['batteries'] as List<dynamic>? ?? [])
          .map(
            (item) => _BatteryOption(
              (item as Map<String, dynamic>)['label'] as String? ?? '',
            ),
          )
          .where((battery) => battery.label.isNotEmpty)
          .toList();
      final records = (telemetryJson['telemetry'] as List<dynamic>? ?? [])
          .map(
            (item) => _TelemetryRecord.fromJson(item as Map<String, dynamic>),
          )
          .toList();
      if (!mounted) return;
      setState(() {
        _teamNumber = team;
        _passcode = passcode;
        _batteries = batteries;
        _records = records;
        _selectedBattery = batteries.any((b) => b.label == _selectedBattery)
            ? _selectedBattery
            : (batteries.isEmpty ? null : batteries.first.label);
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Could not connect. Try again.';
          _loading = false;
        });
      }
    }
  }

  double? _number(TextEditingController controller) {
    final value = controller.text.trim();
    return value.isEmpty ? null : double.tryParse(value);
  }

  Future<void> _save() async {
    if (_selectedBattery == null) return;
    final controllers = [
      _minimumVoltage,
      _secondsBelow8,
      _brownouts,
      _ampHours,
      _resistance,
    ];
    final values = controllers.map(_number).toList();
    final hasInvalidValue = controllers.asMap().entries.any(
      (entry) =>
          entry.value.text.trim().isNotEmpty && values[entry.key] == null,
    );
    if (hasInvalidValue ||
        values.every((value) => value == null) ||
        values.any((value) => value != null && value < 0)) {
      _message('Enter at least one valid, non-negative measurement.');
      return;
    }
    setState(() => _saving = true);
    try {
      final response = await http
          .post(
            Uri.parse('$_apiBase/battery/telemetry'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'teamNumber': _teamNumber,
              'passcode': _passcode,
              'label': _selectedBattery,
              'matchName': _match.text.trim().isEmpty
                  ? 'Practice'
                  : _match.text.trim(),
              'minimumVoltage': _number(_minimumVoltage),
              'secondsBelow8Volts': _number(_secondsBelow8),
              'brownoutCount': _number(_brownouts),
              'ampHoursUsed': _number(_ampHours),
              'internalResistanceMilliohms': _number(_resistance),
            }),
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) throw StateError('Save failed');
      _match.clear();
      _minimumVoltage.clear();
      _secondsBelow8.clear();
      _brownouts.clear();
      _ampHours.clear();
      _resistance.clear();
      await _load();
      _message('Match metrics saved.');
    } catch (_) {
      _message('Could not save match metrics.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _message(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Battery Match Logs'),
      backgroundColor: Colors.white,
    ),
    body: _loading
        ? const Center(child: CircularProgressIndicator(color: _toolColor))
        : _teamNumber == null
        ? _needsTeam()
        : RefreshIndicator(onRefresh: _load, child: _content()),
  );

  Widget _needsTeam() => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.battery_alert_outlined, size: 42, color: _toolColor),
          const SizedBox(height: 12),
          const Text(
            'Set up your battery team first',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          const Text(
            'This tool uses the same team and batteries as the manual tracker.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const BatteryLoginScreen()),
            ).then((_) => _load()),
            child: const Text('Open battery tracker'),
          ),
        ],
      ),
    ),
  );

  Widget _content() => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      const Text(
        'Record a match result',
        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 6),
      const Text(
        'For now, copy values from AdvantageScope. A .wpilog uploader will fill this in automatically later.',
      ),
      const SizedBox(height: 18),
      if (_error != null)
        Text(_error!, style: const TextStyle(color: Colors.red)),
      DropdownButtonFormField<String>(
        key: ValueKey(_selectedBattery),
        initialValue: _selectedBattery,
        decoration: const InputDecoration(
          labelText: 'Battery',
          border: OutlineInputBorder(),
        ),
        items: _batteries
            .map(
              (battery) => DropdownMenuItem(
                value: battery.label,
                child: Text(battery.label),
              ),
            )
            .toList(),
        onChanged: (value) => setState(() => _selectedBattery = value),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _match,
        decoration: const InputDecoration(
          labelText: 'Match name',
          hintText: 'e.g. Practice 3 or Q23',
          border: OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 12),
      _field(_minimumVoltage, 'Minimum voltage', 'Volts, e.g. 7.6'),
      const SizedBox(height: 12),
      _field(_secondsBelow8, 'Time below 8V', 'Seconds, e.g. 1.2'),
      const SizedBox(height: 12),
      _field(_brownouts, 'Brownouts', 'Count, e.g. 0'),
      const SizedBox(height: 12),
      _field(_ampHours, 'Amp-hours used', 'Ah, e.g. 4.6'),
      const SizedBox(height: 12),
      _field(
        _resistance,
        'Estimated internal resistance',
        'Milliohms, e.g. 14.1',
      ),
      const SizedBox(height: 16),
      FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: _toolColor,
          padding: const EdgeInsets.symmetric(vertical: 14),
        ),
        onPressed: _saving || _batteries.isEmpty ? null : _save,
        icon: const Icon(Icons.save_outlined),
        label: Text(_saving ? 'Saving...' : 'Save match metrics'),
      ),
      const SizedBox(height: 26),
      const Text(
        'Recent match metrics',
        style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 8),
      if (_records.isEmpty) const Text('No match metrics yet.'),
      ..._records.map(_recordTile),
    ],
  );

  Widget _field(TextEditingController controller, String label, String hint) =>
      TextField(
        controller: controller,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
        ),
      );

  Widget _recordTile(_TelemetryRecord record) {
    final stats = <String>[
      if (record.minimumVoltage != null)
        '${record.minimumVoltage!.toStringAsFixed(2)} V min',
      if (record.secondsBelow8Volts != null)
        '${record.secondsBelow8Volts!.toStringAsFixed(1)} s < 8V',
      if (record.brownoutCount != null)
        '${record.brownoutCount!.toInt()} brownouts',
      if (record.ampHoursUsed != null)
        '${record.ampHoursUsed!.toStringAsFixed(2)} Ah',
      if (record.internalResistanceMilliohms != null)
        '${record.internalResistanceMilliohms!.toStringAsFixed(1)} mΩ',
    ];
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: _toolColor,
          child: Text(
            record.label,
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ),
        title: Text(record.matchName),
        subtitle: Text(stats.join(' • ')),
      ),
    );
  }
}
