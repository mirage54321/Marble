import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'tap_cursor.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'batteryLOGIN_screen.dart';

const Yellor = Color(0xFFFFC107);
const YellorLight = Color(0xFFFFF4E5);
const YellorDark = Color(0xFFB38600);
const greenChar = Color(0xFF4CAF50);
const redChar = Color(0xFFD93025);

const int kChargeMinutes = 35;
const int kCooldownMinutes = 30;
const int kPollSeconds = 3;
const grayChar = Color(0xFFAAAAAA);
const deadChar = Color(0xFF616161);

class _LabelKey implements Comparable<_LabelKey> {
  final int? number;
  final String raw;

  _LabelKey(this.number, this.raw);

  @override
  int compareTo(_LabelKey other) {
    if (number != null && other.number != null) {
      final cmp = number!.compareTo(other.number!);
      if (cmp != 0) return cmp;
    } else if (number != null) {
      return -1;
    } else if (other.number != null) {
      return 1;
    }
    return raw.compareTo(other.raw);
  }
}

_LabelKey _labelSortKey(String label) {
  final match = RegExp(r'\d+').firstMatch(label);
  final number = match != null ? int.tryParse(match.group(0)!) : null;
  return _LabelKey(number, label);
}

class FlagEntry {
  final String note;
  final DateTime flaggedAt;

  FlagEntry({required this.note, required this.flaggedAt});

  factory FlagEntry.fromJson(Map<String, dynamic> json) {
    return FlagEntry(
      note: json['note'] as String? ?? '',
      flaggedAt: DateTime.parse(json['flaggedAt'] as String),
    );
  }
}


class PendingBatteryAction {
  final String id;
  final String type;
  final String? label;
  final String? note;
  final DateTime queuedAt;

  PendingBatteryAction({
    required this.id,
    required this.type,
    this.label,
    this.note,
    required this.queuedAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'label': label,
        'note': note,
        'queuedAt': queuedAt.toIso8601String(),
      };

  factory PendingBatteryAction.fromJson(Map<String, dynamic> json) {
    return PendingBatteryAction(
      id: json['id'] as String,
      type: json['type'] as String,
      label: json['label'] as String?,
      note: json['note'] as String?,
      queuedAt: DateTime.parse(json['queuedAt'] as String),
    );
  }
}

class Battery {
  final String label;
  DateTime lastUsedAt;
  DateTime? chargedAt;
  final List<FlagEntry> flags;
  bool isCharging;
  bool isInUse;

  Battery({
    required this.label,
    required this.lastUsedAt,
    required this.chargedAt,
    required this.flags,
    required this.isCharging,
    required this.isInUse,
  });

  factory Battery.fromJson(Map<String, dynamic> json) {
    final flagsJson = json['flags'] as List<dynamic>? ?? [];
    final chargedAtRaw = json['chargedAt'] as String?;
    return Battery(
      label: json['label'] as String? ?? '',
      lastUsedAt: DateTime.parse(json['lastUsedAt'] as String),
      chargedAt: chargedAtRaw != null ? DateTime.tryParse(chargedAtRaw) : null,
      flags: flagsJson.map((f) => FlagEntry.fromJson(f as Map<String, dynamic>)).toList(),
      isCharging: json['isCharging'] as bool? ?? false,
      isInUse: json['isInUse'] as bool? ?? false,
    );
  }

  Duration get timeSinceCharged {
    if (chargedAt != null) return DateTime.now().difference(chargedAt!);
    return DateTime.now().difference(lastUsedAt);
  }

  Duration? get chargeTimeRemaining {
    if (!isCharging || chargedAt == null) return null;
    final elapsed = DateTime.now().difference(chargedAt!);
    final remaining = Duration(minutes: kChargeMinutes) - elapsed;
    return remaining.isNegative ? Duration.zero : remaining;
  }

  bool get isChargingComplete {
    final remaining = chargeTimeRemaining;
    return isCharging && remaining != null && remaining == Duration.zero;
  }

  bool get hasBeenUsed => lastUsedAt.isAfter(DateTime(2000));

  bool get isDead {
    if (isInUse || !hasBeenUsed) return false;
    return chargedAt == null || lastUsedAt.isAfter(chargedAt!);
  }

  Duration? get cooldownRemaining {
    if (!isDead) return null;
    final remaining = Duration(minutes: kCooldownMinutes) -
        DateTime.now().difference(lastUsedAt);
    return remaining > Duration.zero ? remaining : null;
  }

  bool get isCoolingDown => cooldownRemaining != null;

  DateTime? get fullyChargedAt =>
      chargedAt?.add(Duration(minutes: kChargeMinutes));
}

class BatteryScreen extends StatefulWidget {
  const BatteryScreen({super.key});

  @override
  State<BatteryScreen> createState() => _BatteryScreenState();
}

class _BatteryScreenState extends State<BatteryScreen>
    with WidgetsBindingObserver {
  static const String _base = 'https://ridgeboticsapp.onrender.com';

  List<Battery> _batteries = [];
  bool _isLoading = true;
  String? _error;
  String? _passcode;
  String? teamNum;
  String? teamName;
  bool _isGuest = false;

  String? _recommendedLabel;
  String? _recommendReason;
  bool _loadingRecommendation = false;

  List<PendingBatteryAction> _pending = [];
  bool _syncing = false;

  Timer? _ticker;
  Timer? _poller;

  int _mutations = 0;
  int _inFlight = 0;
  bool _polling = false;
  String? _lastRawJson;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted) return;
      setState(() {});
      if (_pending.isNotEmpty && !_isGuest) {
        unawaited(_syncPending());
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    _poller?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (teamNum != null) {
        unawaited(_poll());
        _startPolling();
      }
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _poller?.cancel();
    }
  }

  void _startPolling() {
    _poller?.cancel();
    _poller = Timer.periodic(
      const Duration(seconds: kPollSeconds),
      (_) => _poll(),
    );
  }

  Future<void> _poll() async {
    if (!mounted || _polling || _isLoading || teamNum == null) return;
    if (_inFlight > 0 || _pending.isNotEmpty) return;
    _polling = true;
    try {
      await _loadBatteries(silent: true);
    } finally {
      _polling = false;
    }
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    final team = prefs.getString('battery_team');
    final pass = prefs.getString('battery_passcode');
    final guest = prefs.getBool('battery_guest') ?? false;
    final savedTeamName = prefs.getString('battery_team_name');

    if (team == null) {
      if (!mounted) return;
      Navigator.pushReplacement(context,
          MaterialPageRoute(builder: (_) => const BatteryLoginScreen()));
      return;
    }

    teamNum = team;
    _passcode = pass;
    _isGuest = guest;
    teamName = savedTeamName;
    await _loadPending();
    await _loadBatteries();
    if (mounted) _startPolling();
  }

  Future<void> _loadBatteries({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _isLoading = true;
        _error = null;
      });
    }

    final startMutations = _mutations;
    try {
      final uri = _isGuest
          ? Uri.parse('$_base/battery/list?teamNumber=$teamNum&guest=true')
          : Uri.parse('$_base/battery/list?teamNumber=$teamNum&passcode=$_passcode');

      final res = await http.get(uri).timeout(const Duration(seconds: 15));

      if (res.statusCode == 401) { await _logout(); return; }
      if (res.statusCode == 404) {
        if (silent) return;
        setState(() { _error = 'Team not found'; _isLoading = false; });
        return;
      }
      if (res.statusCode != 200) {
        throw StateError('Could not load batteries');
      }

      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final newTeamName = data['teamName'] as String?;
      if (newTeamName != null && newTeamName != teamName) {
        teamName = newTeamName;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('battery_team_name', newTeamName);
      }

      final rawList = data['batteries'] as List<dynamic>? ?? [];

      if (silent && startMutations != _mutations) return;

      final encoded = jsonEncode(rawList);
      if (encoded != _lastRawJson) {
        _lastRawJson = encoded;
        await _cacheBatteriesRaw(rawList);
      }
      final loaded = rawList
          .map((b) => Battery.fromJson(b as Map<String, dynamic>))
          .toList();
      loaded.sort((a, b) => _labelSortKey(a.label).compareTo(_labelSortKey(b.label)));

      setState(() {
        _batteries = loaded;
        _isLoading = false;
        _error = null;
        if (!silent) {
          _recommendedLabel = null;
          _recommendReason = null;
        }
      });

      unawaited(_syncPending());
    } catch (e) {
      if (silent) return;

      final cached = await _readCachedBatteries();
      if (cached != null && cached.isNotEmpty) {
        final cachedAt = await _cachedBatteriesTime();
        setState(() {
          _batteries = cached;
          _isLoading = false;
          _error = cachedAt == null
              ? 'Showing saved batteries. Could not connect'
              : 'Showing batteries from ${_friendlyAgo(cachedAt)}. Could not connect';
        });
      } else {
        setState(() { _error = 'Could not connect, try again'; _isLoading = false; });
      }
    }
  }

  Future<void> _cacheBatteriesRaw(List<dynamic> rawList) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('battery_cache_$teamNum', jsonEncode(rawList));
      await prefs.setInt(
        'battery_cache_${teamNum}_time',
        DateTime.now().millisecondsSinceEpoch,
      );
    } catch (_) {

    }
  }

  Future<List<Battery>?> _readCachedBatteries() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('battery_cache_$teamNum');
      if (raw == null) return null;
      final list = jsonDecode(raw) as List<dynamic>;
      final loaded = list
          .map((b) => Battery.fromJson(b as Map<String, dynamic>))
          .toList();
      loaded.sort((a, b) => _labelSortKey(a.label).compareTo(_labelSortKey(b.label)));
      return loaded;
    } catch (_) {
      return null;
    }
  }

  Future<DateTime?> _cachedBatteriesTime() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ms = prefs.getInt('battery_cache_${teamNum}_time');
      return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
    } catch (_) {
      return null;
    }
  }

  String _friendlyAgo(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours} hr ago';
    return '${diff.inDays} day${diff.inDays == 1 ? '' : 's'} ago';
  }


  Future<void> _loadPending() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList('battery_pending_$teamNum') ?? [];
      _pending = raw
          .map((s) => PendingBatteryAction.fromJson(jsonDecode(s) as Map<String, dynamic>))
          .toList();
    } catch (_) {
      _pending = [];
    }
  }

  Future<void> _savePending() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        'battery_pending_$teamNum',
        _pending.map((p) => jsonEncode(p.toJson())).toList(),
      );
    } catch (_) {

    }
  }

  Future<bool> _sendAction(PendingBatteryAction action) async {
    try {
      late final http.Response res;
      switch (action.type) {
        case 'use':
          res = await http
              .post(Uri.parse('$_base/battery/use'),
                  headers: {'Content-Type': 'application/json'},
                  body: jsonEncode({'teamNumber': teamNum, 'passcode': _passcode, 'label': action.label}))
              .timeout(const Duration(seconds: 10));
          break;
        case 'charging':
          res = await http
              .post(Uri.parse('$_base/battery/charging'),
                  headers: {'Content-Type': 'application/json'},
                  body: jsonEncode({'teamNumber': teamNum, 'passcode': _passcode, 'label': action.label}))
              .timeout(const Duration(seconds: 10));
          break;
        case 'flag':
          res = await http
              .post(Uri.parse('$_base/battery/flag'),
                  headers: {'Content-Type': 'application/json'},
                  body: jsonEncode({
                    'teamNumber': teamNum,
                    'passcode': _passcode,
                    'label': action.label,
                    'note': action.note ?? '',
                  }))
              .timeout(const Duration(seconds: 10));
          break;
        case 'add':
          res = await http
              .post(Uri.parse('$_base/battery/add'),
                  headers: {'Content-Type': 'application/json'},
                  body: jsonEncode({'teamNumber': teamNum, 'passcode': _passcode}))
              .timeout(const Duration(seconds: 10));
          break;
        default:
          return true; 
      }
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }


  Future<void> _dispatchAction(PendingBatteryAction action) async {
    _mutations++;

    if (action.type == 'use' || action.type == 'charging') {
      final existingIndex = _pending.indexWhere(
        (p) => p.type == action.type && p.label == action.label,
      );
      if (existingIndex != -1) {
        setState(() => _pending = [..._pending]..removeAt(existingIndex));
        await _savePending();
        return;
      }
    }

    _inFlight++;
    final bool ok;
    try {
      ok = await _sendAction(action);
    } finally {
      _inFlight--;
    }
    if (ok) {
      unawaited(_loadBatteries(silent: true));
      return;
    }

    setState(() => _pending = [..._pending, action]);
    await _savePending();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('No connection. Saved, will sync automatically')),
    );
  }


  Future<void> _syncPending() async {
    if (_syncing || _pending.isEmpty || _isGuest) return;
    setState(() => _syncing = true);

    var changed = false;
    final remaining = [..._pending];
    while (remaining.isNotEmpty) {
      final ok = await _sendAction(remaining.first);
      if (!ok) break;
      remaining.removeAt(0);
      changed = true;
    }

    setState(() {
      _pending = remaining;
      _syncing = false;
    });
    await _savePending();
    if (changed) await _loadBatteries(silent: true);
  }

  Future<void> _logout() async {
    _ticker?.cancel();
    _poller?.cancel();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('battery_team');
    await prefs.remove('battery_passcode');
    await prefs.remove('battery_guest');
    await prefs.remove('battery_team_name');
    if (!mounted) return;
    Navigator.pushReplacement(context,
        MaterialPageRoute(builder: (_) => const BatteryLoginScreen()));
  }

  Future<void> _toggleInUse(Battery battery) async {
    if (_isGuest) return;
    setState(() {
      battery.isInUse = !battery.isInUse;
      battery.lastUsedAt = DateTime.now();
    });
    await _dispatchAction(PendingBatteryAction(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      type: 'use',
      label: battery.label,
      queuedAt: DateTime.now(),
    ));
  }

  Future<void> _toggleCharging(Battery battery) async {
    if (_isGuest) return;

    if (battery.isCoolingDown && !battery.isCharging) {
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Still cooling down'),
          content: Text(
              '${battery.label} was just used. Give it '
              '${_fmtCeilMinutes(battery.cooldownRemaining ?? Duration.zero)} more to cool '
              'before charging. Charge anyway?'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Wait')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Charge anyway')),
          ],
        ),
      );
      if (go != true || !mounted) return;
    }

    setState(() {
      battery.isCharging = !battery.isCharging;
      if (battery.isCharging) battery.chargedAt = DateTime.now();
    });
    await _dispatchAction(PendingBatteryAction(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      type: 'charging',
      label: battery.label,
      queuedAt: DateTime.now(),
    ));
  }

  Future<void> _askAiRecommendation() async {
    if (_isGuest || _batteries.isEmpty) return;
    setState(() => _loadingRecommendation = true);
    try {
      final res = await http.post(Uri.parse('$_base/battery/recommend'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'teamNumber': teamNum, 'passcode': _passcode}))
          .timeout(const Duration(seconds: 30));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        setState(() {
          _recommendedLabel = data['recommendedLabel'] as String?;
          _recommendReason = data['reason'] as String?;
          _loadingRecommendation = false;
        });
      } else {
        setState(() => _loadingRecommendation = false);
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Could not get a recommendation')));
      }
    } catch (e) {
      setState(() => _loadingRecommendation = false);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Could not connect, try again')));
    }
  }

  Future<void> _flagWeak(Battery battery) async {
    if (_isGuest) return;
    final noteCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Flag ${battery.label}?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Marks this battery as weak or unreliable.'),
            const SizedBox(height: 12),
            TextField(
              controller: noteCtrl,
              maxLines: 2,
              decoration: InputDecoration(
                labelText: 'Reason (optional)',
                hintText: 'e.g. died after auto',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: redChar),
            onPressed: () async {
              Navigator.pop(ctx);
              final note = noteCtrl.text.trim();
              setState(() => battery.flags.add(FlagEntry(note: note, flaggedAt: DateTime.now())));
              await _dispatchAction(PendingBatteryAction(
                id: '${DateTime.now().microsecondsSinceEpoch}',
                type: 'flag',
                label: battery.label,
                note: note,
                queuedAt: DateTime.now(),
              ));
            },
            child: const Text('Flag'),
          ),
        ],
      ),
    );
  }

  Future<void> _addBattery() async {
    if (_isGuest) return;
    await _dispatchAction(PendingBatteryAction(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      type: 'add',
      queuedAt: DateTime.now(),
    ));
  }

  void _viewFlags(Battery battery) {
    if (battery.flags.isEmpty) return;
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${battery.label} flags',
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            const SizedBox(height: 14),
            ...battery.flags.reversed.map((flag) => Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(flag.note.isEmpty ? 'No reason provided' : flag.note),
                      const SizedBox(height: 3),
                      Text(_timeAgo(DateTime.now().difference(flag.flaggedAt)),
                          style: TextStyle(fontSize: 11, color: Colors.grey[600])),
                    ],
                  ),
                )),
          ],
        ),
      ),
    );
  }

  void _showPasscode() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Team Passcode'),
        content: Row(
          children: [
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(color: YellorLight, borderRadius: BorderRadius.circular(10)),
                child: Text(_passcode ?? '',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 18, letterSpacing: 2, fontWeight: FontWeight.bold, color: YellorDark)),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.copy, color: Yellor),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _passcode ?? ''));
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied!')));
              },
            ),
          ],
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))],
      ),
    );
  }

  void _showChangePasscode() {
    final ctrl = TextEditingController();
    String? error;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Change passcode'),
          content: TextField(
            controller: ctrl,
            obscureText: true,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'New passcode',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              errorText: error,
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            TextButton(
              onPressed: () async {
                final newPass = ctrl.text.trim();
                if (newPass.length < 4) { setD(() => error = 'At least 4 characters'); return; }
                try {
                  final res = await http.post(Uri.parse('$_base/battery/changePasscode'),
                      headers: {'Content-Type': 'application/json'},
                      body: jsonEncode({'teamNumber': teamNum, 'passcode': _passcode, 'newPasscode': newPass}));
                  if (res.statusCode == 200) {
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setString('battery_passcode', newPass);
                    setState(() => _passcode = newPass);
                    if (!mounted) return;
                    Navigator.pop(ctx);
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Passcode updated')));
                  } else {
                    setD(() => error = 'Failed, try again');
                  }
                } catch (e) { setD(() => error = 'Could not connect'); }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  void _showStartFresh() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Start fresh?'),
        content: const Text('This will delete ALL batteries for your team. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: redChar),
            onPressed: () async {
              Navigator.pop(ctx);
              try {
                final res = await http.post(Uri.parse('$_base/battery/reset'),
                    headers: {'Content-Type': 'application/json'},
                    body: jsonEncode({'teamNumber': teamNum, 'passcode': _passcode}));
                if (res.statusCode == 200) {
                  await _loadBatteries();
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('All batteries cleared')));
                } else {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not reset, try again')));
                }
              } catch (e) {
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not reset, try again')));
              }
            },
            child: const Text('Delete all'),
          ),
        ],
      ),
    );
  }

  void _showSettings() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Team $teamNum', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
            const SizedBox(height: 4),
            Text(_isGuest ? 'Viewing as guest' : 'Logged in',
                style: TextStyle(fontSize: 13, color: Colors.grey[500])),
            const SizedBox(height: 20),
            if (!_isGuest) ...[
              _settingsTile(Icons.visibility_outlined, 'Show passcode', _showPasscode),
              _settingsTile(Icons.lock_outline, 'Change passcode', _showChangePasscode),
              _settingsTile(Icons.refresh, 'New comp / start fresh', _showStartFresh, color: redChar),
              const SizedBox(height: 8),
            ],
            _settingsTile(Icons.logout, 'Leave team', () { Navigator.pop(ctx); _logout(); }),
          ],
        ),
      ),
    );
  }

  Widget _settingsTile(IconData icon, String label, VoidCallback onTap, {Color? color}) {
    final c = color ?? Colors.black87;
    return TapCursor(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(children: [
          Icon(icon, size: 20, color: c),
          const SizedBox(width: 14),
          Text(label, style: TextStyle(fontSize: 15, color: c)),
        ]),
      ),
    );
  }

  String _fmtCeilMinutes(Duration d) {
    final m = (d.inSeconds / 60).ceil();
    return '${m < 1 ? 1 : m}m';
  }

  String _statusLabel(Battery b) {
    if (b.isInUse) return 'IN USE';
    if (b.isDead) {
      final cd = b.cooldownRemaining;
      if (cd != null) return 'DEAD · COOLING DOWN ${_fmtCeilMinutes(cd)}';
      return 'DEAD · READY TO CHARGE';
    }
    if (b.isCharging) {
      final rem = b.chargeTimeRemaining;
      if (rem == null || rem == Duration.zero) return 'READY';
      final h = rem.inHours;
      final m = rem.inMinutes % 60;
      if (h > 0) return 'CHARGING ${h}h ${m}m left';
      return 'CHARGING ${m}m left';
    }
    return 'AVAILABLE';
  }

  Color _statusColor(Battery b) {
    if (b.isInUse) return redChar;
    if (b.isDead) return b.isCoolingDown ? Colors.blueGrey : deadChar;
    if (b.isCharging) {
      return b.isChargingComplete ? greenChar : Colors.orange;
    }
    return grayChar;
  }

  String _timeAgo(Duration d) {
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ${d.inMinutes % 60}m ago';
    return '${d.inDays}d ago';
  }

  String _chargedLabel(Battery b) {
    if (b.isInUse) {
      return 'Started ${_timeAgo(DateTime.now().difference(b.lastUsedAt))}';
    }
    if (b.isDead) {
      return 'Used ${_timeAgo(DateTime.now().difference(b.lastUsedAt))}, needs a charge';
    }
    if (b.chargedAt == null && !b.hasBeenUsed) return 'Just added';
    if (b.isCharging) {
      final done = b.fullyChargedAt;
      if (done != null && !done.isAfter(DateTime.now())) {
        return 'Fully charged ${_timeAgo(DateTime.now().difference(done))}';
      }
      return 'Charging started ${_timeAgo(DateTime.now().difference(b.chargedAt!))}';
    }
    return 'Charged ${_timeAgo(b.timeSinceCharged)}';
  }

  Battery _localRecommended() {
    for (final b in _batteries) {
      if (!b.isInUse && !b.isDead && (!b.isCharging || b.isChargingComplete)) {
        return b;
      }
    }
    final charging = _batteries
        .where((b) => !b.isInUse && !b.isDead && b.isCharging)
        .toList()
      ..sort((a, b) => (a.chargeTimeRemaining ?? Duration.zero)
          .compareTo(b.chargeTimeRemaining ?? Duration.zero));
    if (charging.isNotEmpty) return charging.first;
    return _batteries.first;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color.fromARGB(255, 255, 255, 248),
      body: SafeArea(
        child: Column(children: [_topBar(), Expanded(child: _body())]),
      ),
    );
  }

  Widget _topBar() {
    final title = teamName != null ? 'Team $teamNum: $teamName' : 'Team $teamNum';
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      child: Row(
        children: [
          TapCursor(
            onTap: () => Navigator.pop(context),
            child: Container(
              width: 34, height: 34,
              decoration: BoxDecoration(color: YellorLight, borderRadius: BorderRadius.circular(10)),
              child: const Icon(Icons.arrow_back, color: Yellor, size: 17),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
              if (_isGuest)
                Text('Guest view (read only)', style: TextStyle(fontSize: 11, color: Colors.grey[500])),
            ]),
          ),
          TapCursor(
            onTap: _showSettings,
            child: Container(
              width: 34, height: 34,
              decoration: BoxDecoration(color: YellorLight, borderRadius: BorderRadius.circular(10)),
              child: const Icon(Icons.more_horiz, color: Yellor, size: 18),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_isLoading) return const Center(child: CircularProgressIndicator(color: Yellor));
    if (_error != null && _batteries.isEmpty) {
      return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Text(_error!, style: TextStyle(color: Colors.grey[600])),
        const SizedBox(height: 12),
        TapCursor(
          onTap: _loadBatteries,
          child: const Text('Try again', style: TextStyle(color: Yellor, fontWeight: FontWeight.w500)),
        ),
      ]));
    }
    return RefreshIndicator(
      color: Yellor,
      onRefresh: _loadBatteries,
      child: _batteries.isEmpty ? _emptyState() : _list(),
    );
  }

  Widget _offlineBanner(String message) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: YellorLight, borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        const Icon(Icons.cloud_off, color: YellorDark, size: 16),
        const SizedBox(width: 8),
        Expanded(child: Text(message, style: const TextStyle(fontSize: 12, color: YellorDark))),
      ]),
    );
  }

  Widget _pendingBanner() {
    final count = _pending.length;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.blueGrey.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(children: [
        _syncing
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.blueGrey),
              )
            : const Icon(Icons.sync, size: 16, color: Colors.blueGrey),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '$count change${count == 1 ? '' : 's'} saved offline. Will sync automatically',
            style: const TextStyle(fontSize: 12, color: Colors.blueGrey),
          ),
        ),
      ]),
    );
  }

  Widget _emptyState() {
    return ListView(padding: const EdgeInsets.all(20), children: [
      if (_error != null) _offlineBanner(_error!),
      if (_pending.isNotEmpty) _pendingBanner(),
      const SizedBox(height: 60),
      Container(
        width: 56, height: 56,
        decoration: BoxDecoration(color: YellorLight, borderRadius: BorderRadius.circular(16)),
        child: const Icon(Icons.battery_charging_full, color: Yellor, size: 28),
      ),
      const SizedBox(height: 16),
      const Text('No batteries yet', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500)),
      const SizedBox(height: 4),
      Text(_isGuest ? 'This team has no batteries logged yet.' : 'Add your first one below.',
          style: TextStyle(fontSize: 13, color: Colors.grey[600])),
      if (!_isGuest) ...[const SizedBox(height: 20), _addButton()],
    ]);
  }

  Widget _list() {
    final recommended = _isGuest ? _localRecommended() : null;
    return ListView(padding: const EdgeInsets.all(16), children: [
      if (_error != null) _offlineBanner(_error!),
      if (_pending.isNotEmpty) _pendingBanner(),
      // Guests can't use the AI endpoint (needs a passcode), so they keep the simple local pick.
      if (_isGuest) _topPick(recommended!) else _aiHeader(),
      const SizedBox(height: 16),
      Text('All batteries',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Colors.grey[600])),
      const SizedBox(height: 8),
      ..._batteries.map(_batteryTile),
      const SizedBox(height: 12),
      if (!_isGuest) _addButton(),
      const SizedBox(height: 16),
    ]);
  }

  Widget _aiHeader() {
    Battery? picked;
    if (_recommendedLabel != null) {
      for (final b in _batteries) {
        if (b.label == _recommendedLabel) {
          picked = b;
          break;
        }
      }
    }
    final charging = picked != null && picked.isCharging && !picked.isDead;

    Widget content;
    if (_loadingRecommendation) {
      content = Row(children: [
        const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
        const SizedBox(width: 12),
        Text('Asking AI...',
            style: TextStyle(fontSize: 15, color: Colors.white.withValues(alpha: 0.9))),
      ]);
    } else if (_recommendedLabel != null) {
      content = Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('AI RECOMMENDS',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: Colors.white.withValues(alpha: 0.8),
                    letterSpacing: 0.5)),
            const SizedBox(height: 4),
            Text(_recommendedLabel!,
                style: const TextStyle(
                    fontSize: 28, fontWeight: FontWeight.w600, color: Colors.white)),
            if (picked != null) ...[
              const SizedBox(height: 3),
              Text(_statusLabel(picked),
                  style: TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w700, color: _statusColor(picked))),
            ],
            if (_recommendReason != null) ...[
              const SizedBox(height: 4),
              Text(_recommendReason!,
                  style: TextStyle(fontSize: 13, color: Colors.white.withValues(alpha: 0.9))),
            ],
            const SizedBox(height: 8),
            TapCursor(
              onTap: _askAiRecommendation,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.refresh, size: 14, color: Colors.white.withValues(alpha: 0.85)),
                const SizedBox(width: 4),
                Text('Ask again',
                    style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.85))),
              ]),
            ),
          ]),
        ),
        if (picked != null)
          Column(children: [
            TapCursor(
              onTap: () => _toggleCharging(picked!),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                    color: charging ? greenChar : Colors.white,
                    borderRadius: BorderRadius.circular(12)),
                child: Text(charging ? 'Charging' : 'Mark charging',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: charging ? Colors.white : YellorDark)),
              ),
            ),
            const SizedBox(height: 8),
            TapCursor(
              onTap: () => _flagWeak(picked!),
              child: Text('Flag weak',
                  style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.85))),
            ),
          ]),
      ]);
    } else {
      content = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('WHICH BATTERY?',
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: Colors.white.withValues(alpha: 0.8),
                letterSpacing: 0.5)),
        const SizedBox(height: 10),
        TapCursor(
          onTap: _askAiRecommendation,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration:
                BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
            child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(Icons.auto_awesome, color: YellorDark, size: 18),
              SizedBox(width: 8),
              Text('Ask AI which battery to use',
                  style: TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600, color: YellorDark)),
            ]),
          ),
        ),
      ]);
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(color: Yellor, borderRadius: BorderRadius.circular(20)),
      child: content,
    );
  }

  Widget _topPick(Battery battery) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(color: Yellor, borderRadius: BorderRadius.circular(20)),
      child: Row(
        children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('RECOMMENDED BATTERY',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500,
                    color: Colors.white.withValues(alpha: 0.8), letterSpacing: 0.5)),
            const SizedBox(height: 4),
            Text(battery.label,
                style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w600, color: Colors.white)),
            const SizedBox(height: 3),
            Text(_statusLabel(battery),
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _statusColor(battery))),
            const SizedBox(height: 2),
            Text(_chargedLabel(battery),
                style: TextStyle(fontSize: 13, color: Colors.white.withValues(alpha: 0.9))),
            if (battery.flags.isNotEmpty) ...[
              const SizedBox(height: 6),
              TapCursor(
                onTap: () => _viewFlags(battery),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.25), borderRadius: BorderRadius.circular(20)),
                  child: Text('Flagged ${battery.flags.length}x',
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: Colors.white)),
                ),
              ),
            ],
          ])),
          if (!_isGuest)
            Column(children: [
              TapCursor(
                onTap: () => _toggleCharging(battery),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                      color: (battery.isCharging && !battery.isDead) ? greenChar : Colors.white,
                      borderRadius: BorderRadius.circular(12)),
                  child: Text((battery.isCharging && !battery.isDead) ? 'Charging' : 'Mark charging',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500,
                          color: (battery.isCharging && !battery.isDead) ? Colors.white : YellorDark)),
                ),
              ),
              const SizedBox(height: 8),
              TapCursor(
                onTap: () => _flagWeak(battery),
                child: Text('Flag weak',
                    style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.85))),
              ),
            ]),
        ],
      ),
    );
  }

  Widget _batteryTile(Battery battery) {
    final statusColor = _statusColor(battery);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.black.withValues(alpha: 0.07), width: 0.5),
      ),
      child: Row(children: [
        Container(
          width: 58, height: 46,
          decoration: BoxDecoration(color: statusColor, borderRadius: BorderRadius.circular(12)),
          alignment: Alignment.center,
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text(battery.label,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.white)),
            if (battery.isInUse)
              const Text('IN USE', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w800, color: Colors.white)),
          ]),
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_statusLabel(battery),
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: statusColor)),
          const SizedBox(height: 2),
          Text(_chargedLabel(battery),
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
          if (battery.flags.isNotEmpty) ...[
            const SizedBox(height: 3),
            TapCursor(
              onTap: () => _viewFlags(battery),
              child: Text('flagged ${battery.flags.length}x, tap to view',
                  style: const TextStyle(fontSize: 11, color: redChar)),
            ),
          ],
        ])),
        if (!_isGuest) ...[
          TapCursor(
            onTap: () => _toggleCharging(battery),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                  color: (battery.isCharging && !battery.isDead)
                      ? greenChar
                      : battery.isCoolingDown
                          ? Colors.blueGrey.withValues(alpha: 0.15)
                          : YellorLight,
                  borderRadius: BorderRadius.circular(10)),
              child: Text((battery.isCharging && !battery.isDead) ? 'Charging' : 'Charge',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500,
                      color: (battery.isCharging && !battery.isDead)
                          ? Colors.white
                          : battery.isCoolingDown
                              ? Colors.blueGrey
                              : YellorDark)),
            ),
          ),
          const SizedBox(width: 6),
          TapCursor(
            onTap: () => _toggleInUse(battery),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                  color: battery.isInUse ? redChar : YellorLight,
                  borderRadius: BorderRadius.circular(10)),
              child: Text(battery.isInUse ? 'In use' : 'Use',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500,
                      color: battery.isInUse ? Colors.white : YellorDark)),
            ),
          ),
          const SizedBox(width: 6),
          TapCursor(
            onTap: () => _flagWeak(battery),
            child: Padding(padding: const EdgeInsets.all(8),
                child: Icon(Icons.flag_outlined, size: 16, color: Colors.grey[500])),
          ),
        ],
      ]),
    );
  }

  Widget _addButton() {
    return TapCursor(
      onTap: _addBattery,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 13),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.black.withValues(alpha: 0.1), width: 0.5),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.add, color: Yellor, size: 18),
          const SizedBox(width: 7),
          Text('Add battery',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Colors.grey[700])),
        ]),
      ),
    );
  }
}