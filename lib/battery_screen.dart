import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'tap_cursor.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'batteryLOGIN_screen.dart';
import 'battery_detail_screen.dart';
import 'connector_setup_screen.dart';

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



const nodeOnColor = Color(0xFF2E9E55);
const nodeOffColor = Color(0xFF4A4A4A);
const int kNodeOnlineMinutes = 5;

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
  String? name;
  DateTime lastUsedAt;
  DateTime? chargedAt;
  final List<FlagEntry> flags;
  bool isCharging;
  bool isInUse;
  double? lastVoltage;
  DateTime? lastVoltageAt;

  Battery({
    required this.label,
    this.name,
    required this.lastUsedAt,
    required this.chargedAt,
    required this.flags,
    required this.isCharging,
    required this.isInUse,
    this.lastVoltage,
    this.lastVoltageAt,
  });

  factory Battery.fromJson(Map<String, dynamic> json) {
    final flagsJson = json['flags'] as List<dynamic>? ?? [];
    final chargedAtRaw = json['chargedAt'] as String?;
    return Battery(
      label: json['label'] as String? ?? '',
      name: json['name'] as String?,
      lastUsedAt: DateTime.parse(json['lastUsedAt'] as String),
      chargedAt: chargedAtRaw != null ? DateTime.tryParse(chargedAtRaw) : null,
      flags: flagsJson.map((f) => FlagEntry.fromJson(f as Map<String, dynamic>)).toList(),
      isCharging: json['isCharging'] as bool? ?? false,
      isInUse: json['isInUse'] as bool? ?? false,
      lastVoltage: (json['lastVoltage'] as num?)?.toDouble(),
      lastVoltageAt: DateTime.tryParse(json['lastVoltageAt'] as String? ?? ''),
    );
  }


  Duration? get nodeAge => (lastVoltage == null || lastVoltageAt == null)
      ? null
      : DateTime.now().difference(lastVoltageAt!);


  bool get nodeConnected {
    final age = nodeAge;
    return age != null && age < const Duration(minutes: kNodeOnlineMinutes);
  }

  String get displayName =>
      (name != null && name!.trim().isNotEmpty) ? name!.trim() : label;

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

String timeAgoText(Duration d) {
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ${d.inMinutes % 60}m ago';
  return '${d.inDays}d ago';
}

String fmtCeilMinutes(Duration d) {
  final m = (d.inSeconds / 60).ceil();
  return '${m < 1 ? 1 : m}m';
}

String batteryStatusLabel(Battery b) {
  if (b.isInUse) return 'IN USE';
  if (b.isDead) {
    final cd = b.cooldownRemaining;
    if (cd != null) return 'DEAD · COOLING DOWN ${fmtCeilMinutes(cd)}';
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

Color batteryStatusColor(Battery b) {
  if (b.isInUse) return redChar;
  if (b.isDead) return b.isCoolingDown ? Colors.blueGrey : deadChar;
  if (b.isCharging) {
    return b.isChargingComplete ? greenChar : Colors.orange;
  }
  return grayChar;
}

String batteryChargedLabel(Battery b) {
  if (b.isInUse) {
    return 'Started ${timeAgoText(DateTime.now().difference(b.lastUsedAt))}';
  }
  if (b.isDead) {
    return 'Used ${timeAgoText(DateTime.now().difference(b.lastUsedAt))}, needs a charge';
  }
  if (b.chargedAt == null && !b.hasBeenUsed) return 'Just added';
  if (b.isCharging) {
    final done = b.fullyChargedAt;
    if (done != null && !done.isAfter(DateTime.now())) {
      return 'Fully charged ${timeAgoText(DateTime.now().difference(done))}';
    }
    return 'Charging started ${timeAgoText(DateTime.now().difference(b.chargedAt!))}';
  }
  return 'Charged ${timeAgoText(b.timeSinceCharged)}';
}


String batteryNodeLine(Battery b) =>
    b.nodeConnected ? '${b.lastVoltage!.toStringAsFixed(2)} V' : 'Not connected';




class BatteryIcon extends StatelessWidget {
  final Battery battery;
  final double height;

  const BatteryIcon({super.key, required this.battery, this.height = 58});

  @override
  Widget build(BuildContext context) {
    final on = battery.nodeConnected;
    return CustomPaint(
      size: Size(height * 48 / 66, height),
      painter: _BatteryIconPainter(
          color: on ? nodeOnColor : nodeOffColor, full: on),
    );
  }
}

class _BatteryIconPainter extends CustomPainter {
  final Color color;
  final bool full;

  _BatteryIconPainter({required this.color, required this.full});

  @override
  void paint(Canvas canvas, Size size) {

    final sx = size.width / 48, sy = size.height / 66;
    RRect box(double x, double y, double w, double h, double r) =>
        RRect.fromRectAndRadius(
            Rect.fromLTWH(x * sx, y * sy, w * sx, h * sy), Radius.circular(r * sx));

    final solid = Paint()..color = color;
    canvas.drawRRect(box(17, 2, 14, 6, 2), solid);
    canvas.drawRRect(
        box(5, 8, 38, 56, 7),
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3 * sx);
    if (full) {
      canvas.drawRRect(box(10, 12, 28, 48, 3), solid);
    } else {
      canvas.drawRRect(
          box(16, 34, 16, 4, 2), Paint()..color = color.withValues(alpha: 0.55));
    }
  }

  @override
  bool shouldRepaint(covariant _BatteryIconPainter old) =>
      old.color != color || old.full != full;
}


class _NodeInfo {
  final String nodeId;
  final int? number;
  final String? label;
  final double? volts;
  final DateTime? lastSeenAt;
  final bool connected;

  const _NodeInfo({
    required this.nodeId,
    this.number,
    this.label,
    this.volts,
    this.lastSeenAt,
    required this.connected,
  });

  factory _NodeInfo.fromJson(Map<String, dynamic> j) => _NodeInfo(
        nodeId: j['nodeId'] as String? ?? '',
        number: (j['number'] as num?)?.toInt(),
        label: j['label'] as String?,
        volts: (j['volts'] as num?)?.toDouble(),
        lastSeenAt: DateTime.tryParse(j['lastSeenAt'] as String? ?? ''),
        connected: j['connected'] == true,
      );

  String get title => 'Node ${number ?? nodeId}';
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



  bool _teamAuto = false;
  bool _autoMode = false;

  bool _collectorConnected = false;


  List<_NodeInfo> _nodes = [];
  final ValueNotifier<int> _nodesRev = ValueNotifier<int>(0);
  DateTime _lastRecAt = DateTime.fromMillisecondsSinceEpoch(0);



  bool _nodesHover = false;
  Timer? _nodesPeekTimer;
  static const Color _nodeInk = Color(0xFF2B2410);



  bool get _showFlags => true;

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
      if (!_isGuest && _teamAuto && teamNum != null) {
        unawaited(_loadNodes());

        if (_autoMode &&
            DateTime.now().difference(_lastRecAt) > const Duration(minutes: 3)) {
          unawaited(_askAiRecommendation(quiet: true));
        }
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    _nodesPeekTimer?.cancel();
    _nodesRev.dispose();
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

    _teamAuto = prefs.getString('battery_mode_$team') == 'auto';
    _autoMode = !guest && _teamAuto;
    await _loadPending();
    await _loadBatteries();
    if (_teamAuto) unawaited(_loadNodes());
    if (mounted) _startPolling();




    if (!guest && prefs.getBool('battery_connector_ask_$team') == true) {
      if (mounted) {
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _askConnectorFirstTime());
      }
    }
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
          : Uri.parse('$_base/battery/list?teamNumber=$teamNum');


      final res = await http
          .get(uri,
              headers: _isGuest ? null : {'X-Team-Passcode': _passcode ?? ''})
          .timeout(const Duration(seconds: 15));

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

      await _applyServerMode(
          data['mode'] as String?, data['connectorConnected'] == true);

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

      if (!silent && _autoMode && !_isGuest) {
        unawaited(_askAiRecommendation(quiet: true));
      }

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




  Future<void> _applyServerMode(String? mode, bool connected) async {
    if (mode == null || !mounted) return;
    final auto = mode == 'auto';
    final nowConnected = auto && connected;
    final modeChanged = auto != _teamAuto;

    if (modeChanged || nowConnected != _collectorConnected) {
      setState(() {
        _teamAuto = auto;
        _autoMode = auto && !_isGuest;
        _collectorConnected = nowConnected;
        if (modeChanged) {
          _recommendedLabel = null;
          _recommendReason = null;
        }
      });
    }
    if (modeChanged) {
      if (_autoMode && !_isGuest) {
        unawaited(_loadNodes());
        unawaited(_askAiRecommendation(quiet: true));
      }
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('battery_mode_$teamNum', auto ? 'auto' : 'manual');
      } catch (_) {}
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
        case 'rename':
          res = await http
              .post(Uri.parse('$_base/battery/rename'),
                  headers: {'Content-Type': 'application/json'},
                  body: jsonEncode({
                    'teamNumber': teamNum,
                    'passcode': _passcode,
                    'label': action.label,
                    'name': action.note ?? '',
                  }))
              .timeout(const Duration(seconds: 10));


          if (res.statusCode == 400 ||
              res.statusCode == 404 ||
              res.statusCode == 409) {
            return true;
          }
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



      if ((action.type == 'use' || action.type == 'charging') &&
          res.statusCode == 409) {
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



    final team = teamNum;
    if (team != null) {
      await prefs.remove('battery_cache_$team');
      await prefs.remove('battery_cache_${team}_time');
      await prefs.remove('battery_pending_$team');
      await prefs.remove('battery_mode_$team');
      await prefs.remove('battery_connector_ask_$team');
    }
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
              '${battery.displayName} was just used. Give it '
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


  Future<void> _askAiRecommendation({bool quiet = false}) async {
    if (_isGuest || _batteries.isEmpty) return;
    _lastRecAt = DateTime.now();
    if (!quiet || _recommendedLabel == null) {
      setState(() => _loadingRecommendation = true);
    }
    try {
      final res = await http
          .post(Uri.parse('$_base/battery/recommend'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'teamNumber': teamNum, 'passcode': _passcode}))
          .timeout(const Duration(seconds: 30));
      if (!mounted) return;

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        setState(() {
          _recommendedLabel = data['recommendedLabel'] as String?;
          _recommendReason = data['reason'] as String?;
          _loadingRecommendation = false;
        });
      } else {
        setState(() => _loadingRecommendation = false);
        if (!quiet) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Could not get a recommendation')));
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingRecommendation = false);
      if (!quiet) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not connect, try again')));
      }
    }
  }



  Future<void> _loadNodes() async {
    if (_isGuest || teamNum == null) return;
    try {
      final res = await http
          .get(
              Uri.parse(
                  '$_base/battery/nodes?teamNumber=${Uri.encodeQueryComponent(teamNum!)}'),
              headers: {'X-Team-Passcode': _passcode ?? ''})
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200 || !mounted) return;
      _applyNodes(jsonDecode(res.body) as Map<String, dynamic>);
    } catch (_) {

    }
  }

  void _applyNodes(Map<String, dynamic> data) {
    final list = (data['nodes'] as List<dynamic>? ?? [])
        .map((n) => _NodeInfo.fromJson(n as Map<String, dynamic>))
        .toList();
    setState(() => _nodes = list);
    _nodesRev.value++;
  }



  Future<String?> _assignNode(_NodeInfo node, String label) async {
    try {
      final res = await http
          .post(Uri.parse('$_base/battery/nodes/assign'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'teamNumber': teamNum,
                'passcode': _passcode,
                'nodeId': node.nodeId,
                'label': label.isEmpty ? null : label,
              }))
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) {
        try {
          return (jsonDecode(res.body) as Map<String, dynamic>)['error'] as String? ??
              'Could not change it';
        } catch (_) {
          return 'Could not change it';
        }
      }
      if (!mounted) return null;
      _mutations++;
      _applyNodes(jsonDecode(res.body) as Map<String, dynamic>);
      unawaited(_loadBatteries(silent: true));
      if (_autoMode) unawaited(_askAiRecommendation(quiet: true));
      return null;
    } catch (_) {
      return 'Could not connect, try again';
    }
  }

  String _nodeBatteryName(String? label) {
    for (final b in _batteries) {
      if (b.label == label) return b.displayName;
    }
    return 'no battery';
  }




  Widget _nodesButton() {
    final active = _nodes.where((n) => n.connected).toList();
    final maxPopupWidth =
        (MediaQuery.sizeOf(context).width - 48).clamp(200.0, 320.0).toDouble();
    return MouseRegion(
      onEnter: (_) => setState(() => _nodesHover = true),
      onExit: (_) => setState(() => _nodesHover = false),
      child: Stack(clipBehavior: Clip.none, children: [
        Semantics(
          button: true,
          label: 'Sensor nodes. Change which battery each is on',
          child: Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: Yellor,
              shape: BoxShape.circle,
              border: Border.all(color: _nodeInk, width: 2),
              boxShadow: [
                BoxShadow(
                    color: _nodeInk.withValues(alpha: 0.22),
                    blurRadius: 14,
                    offset: const Offset(0, 4)),
              ],
            ),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: _showNodes,
                onLongPress: _peekNodes,
                child: const Center(
                    child: Icon(Icons.sensors, size: 26, color: _nodeInk)),
              ),
            ),
          ),
        ),
        if (active.isNotEmpty)
          Positioned(
            top: -6,
            right: -6,
            child: Container(
              constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
              padding: const EdgeInsets.symmetric(horizontal: 5),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: nodeOnColor,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                    color: const Color.fromARGB(255, 255, 255, 248), width: 2),
              ),
              child: Text('${active.length}',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w800)),
            ),
          ),
        if (_nodesHover)
          Positioned(
            right: 0,
            bottom: 66,
            child: IgnorePointer(child: _nodesPopup(active, maxPopupWidth)),
          ),
      ]),
    );
  }

  void _peekNodes() {
    _nodesPeekTimer?.cancel();
    setState(() => _nodesHover = true);
    _nodesPeekTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _nodesHover = false);
    });
  }


  Widget _nodesPopup(List<_NodeInfo> active, double maxWidth) {
    final minWidth = maxWidth < 240 ? maxWidth : 240.0;
    return Container(
      constraints: BoxConstraints(minWidth: minWidth, maxWidth: maxWidth),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _nodeInk, width: 1.5),
        boxShadow: [
          BoxShadow(
              color: _nodeInk.withValues(alpha: 0.2),
              blurRadius: 24,
              offset: const Offset(0, 8)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
              active.isEmpty
                  ? 'No nodes sending right now'
                  : '${active.length} node${active.length == 1 ? '' : 's'} active',
              style: const TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w700, color: _nodeInk)),
          for (final n in active)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.circle, size: 10, color: nodeOnColor),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                      '${n.title} → ${_nodeBatteryName(n.label)}${n.volts != null ? ' · ${n.volts!.toStringAsFixed(2)} V' : ''}',
                      style: const TextStyle(fontSize: 14, color: _nodeInk)),
                ),
              ]),
            ),
          const SizedBox(height: 6),
          Text('Tap to change which battery a node is on',
              style: TextStyle(fontSize: 13, color: Colors.grey[600])),
        ],
      ),
    );
  }

  void _showNodes() {
    unawaited(_loadNodes());
    final error = ValueNotifier<String?>(null);
    final busy = ValueNotifier<String?>(null);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: AnimatedBuilder(
          animation: Listenable.merge([_nodesRev, error, busy]),
          builder: (ctx, _) => SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Sensor nodes',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(
                    'Pick which battery each node is on. If that battery already has a node, the two swap.',
                    style: TextStyle(fontSize: 12.5, color: Colors.grey[600])),
                const SizedBox(height: 12),
                if (_nodes.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    child: Text(
                        'No sensor nodes have reported yet. Turn on a node and the Pi. It shows up here once Marble hears from it.',
                        style: TextStyle(fontSize: 13, color: Colors.grey[600])),
                  ),
                for (final n in _nodes) _nodeRow(n, busy, error),
                if (error.value != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(error.value!,
                        style: const TextStyle(color: redChar, fontSize: 13)),
                  ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      backgroundColor: Yellor,
                      foregroundColor: _nodeInk,
                      side: const BorderSide(color: _nodeInk, width: 1.5),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Done',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _nodeRow(
      _NodeInfo n, ValueNotifier<String?> busy, ValueNotifier<String?> error) {
    final status = n.connected
        ? 'Sending${n.volts != null ? ' · ${n.volts!.toStringAsFixed(2)} V' : ''}'
        : n.lastSeenAt == null
            ? 'Not connected'
            : 'Not connected · last seen ${timeAgoText(DateTime.now().difference(n.lastSeenAt!))}';
    final known = n.label != null && _batteries.any((b) => b.label == n.label);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
          border: Border(top: BorderSide(color: Colors.black.withValues(alpha: 0.07)))),
      child: Row(children: [
        Icon(Icons.circle, size: 10, color: n.connected ? nodeOnColor : nodeOffColor),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(n.title,
                style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
            Text(status, style: TextStyle(fontSize: 12, color: Colors.grey[600])),
          ]),
        ),
        DropdownButton<String>(
          value: known ? n.label : '',
          underline: const SizedBox.shrink(),
          items: [
            const DropdownMenuItem<String>(value: '', child: Text('No battery')),
            for (final b in _batteries)
              DropdownMenuItem<String>(value: b.label, child: Text(b.displayName)),
          ],
          onChanged: busy.value != null
              ? null
              : (v) async {
                  if (v == null) return;
                  busy.value = n.nodeId;
                  error.value = null;
                  final err = await _assignNode(n, v);
                  busy.value = null;
                  error.value = err;
                },
        ),
      ]),
    );
  }

  Future<void> _flagWeak(Battery battery) async {
    if (_isGuest) return;
    final noteCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Flag ${battery.displayName}?'),
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

  Future<void> _renameBattery(Battery battery) async {
    if (_isGuest) return;
    final ctrl = TextEditingController(text: battery.name ?? '');
    String? error;
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text('Rename ${battery.displayName}'),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            maxLength: 10,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              labelText: 'Name',
              hintText: 'e.g. Barbra',
              helperText: 'Leave empty to go back to ${battery.label}',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              errorText: error,
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            TextButton(
              onPressed: () {
                final name = ctrl.text.trim();
                final lower = name.toLowerCase();
                final taken = name.isNotEmpty &&
                    _batteries.any((b) =>
                        b.label != battery.label &&
                        (b.label.toLowerCase() == lower ||
                            (b.name ?? '').toLowerCase() == lower));
                if (taken) {
                  setD(() => error = 'Another battery already has that name');
                  return;
                }
                Navigator.pop(ctx, name);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (result == null || !mounted) return;
    if (result == (battery.name ?? '')) return;
    setState(() => battery.name = result.isEmpty ? null : result);
    await _dispatchAction(PendingBatteryAction(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      type: 'rename',
      label: battery.label,
      note: result,
      queuedAt: DateTime.now(),
    ));
  }



  Future<bool> _deleteBattery(Battery battery, {required bool dataOnly}) async {
    if (_isGuest) return false;
    final label = Uri.encodeComponent(battery.label);
    final team = Uri.encodeQueryComponent(teamNum ?? '');
    final url = '$_base/battery/$label${dataOnly ? '/data' : ''}?teamNumber=$team';
    try {
      final res = await http
          .delete(Uri.parse(url),
              headers: {
                'Content-Type': 'application/json',
                'X-Team-Passcode': _passcode ?? '',
              },
              body: jsonEncode({'teamNumber': teamNum, 'passcode': _passcode}))
          .timeout(const Duration(seconds: 15));

      if (res.statusCode != 200 && res.statusCode != 404) {
        throw StateError('delete ${res.statusCode}');
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Could not delete, check your connection and try again')));
      }
      return false;
    }
    _mutations++;
    if (!mounted) return true;
    setState(() {

      _pending = _pending.where((p) => p.label != battery.label).toList();
      if (dataOnly) {
        battery.lastVoltage = null;
        battery.lastVoltageAt = null;
        battery.flags.clear();
      } else {
        _batteries = _batteries.where((x) => x.label != battery.label).toList();
      }
      if (_recommendedLabel == battery.label) {
        _recommendedLabel = null;
        _recommendReason = null;
      }
    });
    await _savePending();
    unawaited(_loadBatteries(silent: true));
    return true;
  }

  void _showBatteryMenu(Battery battery) {
    if (_isGuest) return;
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            _menuRow(Icons.edit_outlined, 'Rename battery', () {
              Navigator.pop(ctx);
              _renameBattery(battery);
            }),
            _menuRow(Icons.delete_sweep_outlined, 'Delete data', () {
              Navigator.pop(ctx);
              _confirmDeleteData(battery);
            }),
            _menuRow(Icons.close, 'Delete battery', () {
              Navigator.pop(ctx);
              _confirmDeleteBattery(battery);
            }, color: redChar),
            const Divider(height: 8),
            _menuRow(null, 'Cancel', () => Navigator.pop(ctx),
                color: Colors.grey[600]),
          ]),
        ),
      ),
    );
  }

  Widget _menuRow(IconData? icon, String label, VoidCallback onTap,
      {Color? color}) {
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

  Future<void> _confirmDeleteData(Battery battery) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete data for ${battery.displayName}?'),
        content: const Text(
            'This clears its robot logs, voltage readings and flags. The battery stays. This can\'t be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: redChar),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete data')),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    await _deleteBattery(battery, dataOnly: true);
  }

  Future<void> _confirmDeleteBattery(Battery battery) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${battery.displayName}?'),
        content: const Text(
            'This removes the battery and everything recorded for it. This can\'t be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: redChar),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete battery')),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    await _deleteBattery(battery, dataOnly: false);
  }

  Future<void> _addBattery() async {
    if (_isGuest) return;
    await _dispatchAction(PendingBatteryAction(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      type: 'add',
      queuedAt: DateTime.now(),
    ));
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

  static const String _connectorBlurb =
      'Marble Connector Desktop is a small app on your computer. It reads '
      'your robot\'s match logs and keeps track of your batteries for you. '
      'Marble then just shows your batteries and which one to use, with no '
      'buttons to tap.';



  Future<bool> _setMode(bool auto, {String? collectorPassword}) async {
    try {
      final res = await http
          .post(Uri.parse('$_base/battery/mode'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'teamNumber': teamNum,
                'passcode': _passcode,
                'mode': auto ? 'auto' : 'manual',
                if (collectorPassword != null)
                  'collectorPassword': collectorPassword,
              }))
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) throw StateError('mode ${res.statusCode}');
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Could not change the mode, check your connection and try again')));
      }
      return false;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('battery_mode_$teamNum', auto ? 'auto' : 'manual');
    } catch (_) {}
    if (!mounted) return true;
    _mutations++;
    setState(() {
      _teamAuto = auto;
      _autoMode = auto && !_isGuest;
      _collectorConnected = false;
      _recommendedLabel = null;
      _recommendReason = null;
      _pending = [];
      for (final b in _batteries) {
        b.isCharging = false;
        b.isInUse = false;
        b.chargedAt = null;
        b.lastUsedAt = DateTime.fromMillisecondsSinceEpoch(0);
      }
    });
    await _savePending();
    unawaited(_loadBatteries(silent: true));
    return true;
  }

  Future<bool> _openConnectorSetup({bool instructionsOnly = false}) async {
    if (instructionsOnly) {
      final unlocked = await promptCollectorPassword(context);
      if (unlocked == null || !mounted) return false;
    }
    final done = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            ConnectorSetupScreen(instructionsOnly: instructionsOnly),
      ),
    );
    return done == true;
  }

  Future<void> _startConnectorSetup() async {
    final wasAuto = _teamAuto;

    String? unlocked;
    if (!wasAuto) {
      unlocked = await promptCollectorPassword(context);
      if (unlocked == null || !mounted) return;
      if (!await _setMode(true, collectorPassword: unlocked)) return;
    }
    final done = await _openConnectorSetup();


    if (!done && !wasAuto && mounted && !_collectorConnected) {
      await _setMode(false);
    }
  }

  Future<void> _clearConnectorAsk() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('battery_connector_ask_$teamNum');
    } catch (_) {}
  }

  Future<void> _askConnectorFirstTime() async {
    if (!mounted) return;

    if (_teamAuto) {
      await _clearConnectorAsk();
      return;
    }
    final yes = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Use Marble Connector Desktop?'),
        content: const Text(_connectorBlurb),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('No, keep it manual')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Yellor),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Yes, set it up')),
        ],
      ),
    );
    await _clearConnectorAsk();
    if (yes == true) {
      await _startConnectorSetup();
    }

  }

  Future<void> _confirmSwitchToConnector() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Switch to Marble Connector Desktop?'),
        content: const Text(_connectorBlurb),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Yellor),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Switch')),
        ],
      ),
    );
    if (yes == true) await _startConnectorSetup();
  }

  Future<void> _confirmSwitchToManual() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Switch back to manual?'),
        content: const Text(
            'The Use, Charge and Flag buttons will come back and you will '
            'track batteries by hand again.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Yellor),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Switch to manual')),
        ],
      ),
    );
    if (yes == true) await _setMode(false);
  }

  void _showSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
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

                if (_autoMode) ...[
                  Row(children: [
                    Icon(Icons.circle,
                        size: 9, color: _collectorConnected ? nodeOnColor : nodeOffColor),
                    const SizedBox(width: 8),
                    Text(
                        _collectorConnected
                            ? 'Marble Connector Desktop is connected'
                            : 'Waiting for Marble Connector Desktop',
                        style: TextStyle(fontSize: 13, color: Colors.grey[700])),
                  ]),
                  _settingsTile(Icons.help_outline, 'Connector instructions', () {
                    Navigator.pop(ctx);
                    _openConnectorSetup(instructionsOnly: true);
                  }),
                  _settingsTile(Icons.swap_horiz, 'Switch to manual tracking', () {
                    Navigator.pop(ctx);
                    _confirmSwitchToManual();
                  }),
                ] else
                  _settingsTile(Icons.computer, 'Track with Marble Connector Desktop', () {
                    Navigator.pop(ctx);
                    _confirmSwitchToConnector();
                  }),
                const Divider(height: 24),
                _settingsTile(Icons.visibility_outlined, 'Show passcode', _showPasscode),
                _settingsTile(Icons.lock_outline, 'Change passcode', _showChangePasscode),
                _settingsTile(Icons.refresh, 'New comp / start fresh', _showStartFresh, color: redChar),
                const SizedBox(height: 8),
              ],
              _settingsTile(Icons.logout, 'Leave team', () { Navigator.pop(ctx); _logout(); }),
            ],
          ),
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

  String _fmtCeilMinutes(Duration d) => fmtCeilMinutes(d);
  String _chargedLabel(Battery b) => batteryChargedLabel(b);



  Battery? _localRecommended() {
    if (_teamAuto) {


      final ok = _batteries
          .where((b) =>
              b.lastVoltage != null &&
              (!b.nodeConnected || b.lastVoltage! >= 11.8))
          .toList()
        ..sort((a, b) {
          if (a.nodeConnected != b.nodeConnected) return a.nodeConnected ? -1 : 1;
          return (b.lastVoltage ?? 0).compareTo(a.lastVoltage ?? 0);
        });
      return ok.isNotEmpty ? ok.first : null;
    }
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
      floatingActionButton: _isGuest || !_teamAuto ? null : _nodesButton(),
      bottomNavigationBar: _teamAuto && !_isLoading
          ? SafeArea(
              top: false,
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: _legend(),
              ),
            )
          : null,
      body: SafeArea(
        child: Column(children: [
          _topBar(),
          Expanded(child: _body()),
        ]),
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
                Text('Guest view (read only)', style: TextStyle(fontSize: 11, color: Colors.grey[500]))
              else if (_autoMode)
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.circle,
                      size: 7, color: _collectorConnected ? nodeOnColor : nodeOffColor),
                  const SizedBox(width: 5),
                  Text(_collectorConnected ? 'Connector connected' : 'Waiting for connector',
                      style: TextStyle(fontSize: 11, color: Colors.grey[500])),
                ]),
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


  String? get _suggestedLabel {
    if (_batteries.isEmpty) return null;
    if (_isGuest) return _localRecommended()?.label;
    return _recommendedLabel;
  }

  void _openDetail(Battery b) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => BatteryDetailScreen(
          label: b.label,
          team: teamNum ?? '',
          passcode: _passcode,
          isGuest: _isGuest,
          autoMode: _autoMode,
          showFlags: _showFlags,
          lookup: () {
            for (final x in _batteries) {
              if (x.label == b.label) return x;
            }
            return null;
          },
          onRename: _renameBattery,
          onToggleInUse: _toggleInUse,
          onToggleCharging: _toggleCharging,
          onFlag: _flagWeak,
          onDelete: _deleteBattery,
        ),
      ),
    );
  }

  Widget _list() {
    return _teamAuto ? _automaticList() : _manualList();
  }

  Widget _automaticList() {
    return ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 96), children: [
      if (_error != null) _offlineBanner(_error!),
      if (_pending.isNotEmpty) _pendingBanner(),
      _suggestionBar(),
      const SizedBox(height: 16),
      _grid(),
      const SizedBox(height: 18),
      if (!_isGuest) _addButton(),
      const SizedBox(height: 16),
    ]);
  }

  Widget _manualList() {
    final recommended = _isGuest ? _localRecommended() : null;
    return ListView(padding: const EdgeInsets.all(16), children: [
      if (_error != null) _offlineBanner(_error!),
      if (_pending.isNotEmpty) _pendingBanner(),
      if (_isGuest) _manualTopPick(recommended!) else _manualAiHeader(),
      const SizedBox(height: 16),
      Row(children: [
        Expanded(
          child: Text('All batteries',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Colors.grey[600])),
        ),
      ]),
      const SizedBox(height: 8),
      ..._batteries.map(_manualBatteryTile),
      const SizedBox(height: 12),
      if (!_isGuest) _addButton(),
      const SizedBox(height: 16),
    ]);
  }

  Widget _manualAiHeader() {
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
        const SizedBox(width: 18, height: 18,
            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
        const SizedBox(width: 12),
        Text('Asking AI...', style: TextStyle(fontSize: 15, color: Colors.white.withValues(alpha: 0.9))),
      ]);
    } else if (_recommendedLabel != null) {
      content = Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('AI RECOMMENDS', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500,
              color: Colors.white.withValues(alpha: 0.8), letterSpacing: 0.5)),
          const SizedBox(height: 4),
          Text(picked?.displayName ?? _recommendedLabel!,
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w600, color: Colors.white)),
          if (picked != null) ...[
            const SizedBox(height: 3),
            Text(batteryStatusLabel(picked), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
                color: batteryStatusColor(picked))),
          ],
          if (_recommendReason != null) ...[
            const SizedBox(height: 4),
            Text(_recommendReason!, style: TextStyle(fontSize: 13, color: Colors.white.withValues(alpha: 0.9))),
          ],
          const SizedBox(height: 8),
          TapCursor(onTap: _askAiRecommendation, child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.refresh, size: 14, color: Colors.white.withValues(alpha: 0.85)),
            const SizedBox(width: 4),
            Text('Ask again', style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.85))),
          ])),
        ])),
        if (picked != null) Column(children: [
          TapCursor(onTap: () => _toggleCharging(picked!), child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(color: charging ? greenChar : Colors.white,
                borderRadius: BorderRadius.circular(12)),
            child: Text(charging ? 'Charging' : 'Mark charging', style: TextStyle(fontSize: 13,
                fontWeight: FontWeight.w500, color: charging ? Colors.white : YellorDark)),
          )),
          const SizedBox(height: 8),
          TapCursor(onTap: () => _flagWeak(picked!), child: Text('Flag weak',
              style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.85)))),
        ]),
      ]);
    } else {
      content = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('WHICH BATTERY?', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500,
            color: Colors.white.withValues(alpha: 0.8), letterSpacing: 0.5)),
        const SizedBox(height: 10),
        TapCursor(onTap: _askAiRecommendation, child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14)),
          child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.auto_awesome, color: YellorDark, size: 18),
            SizedBox(width: 8),
            Text('Ask AI which battery to use', style: TextStyle(fontSize: 14,
                fontWeight: FontWeight.w600, color: YellorDark)),
          ]),
        )),
      ]);
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(color: Yellor, borderRadius: BorderRadius.circular(20)),
      child: content,
    );
  }

  Widget _manualTopPick(Battery battery) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(color: Yellor, borderRadius: BorderRadius.circular(20)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('RECOMMENDED BATTERY', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500,
            color: Colors.white.withValues(alpha: 0.8), letterSpacing: 0.5)),
        const SizedBox(height: 4),
        Text(battery.displayName,
            style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w600, color: Colors.white)),
        const SizedBox(height: 3),
        Text(batteryStatusLabel(battery),
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: batteryStatusColor(battery))),
        const SizedBox(height: 2),
        Text(_chargedLabel(battery), style: TextStyle(fontSize: 13, color: Colors.white.withValues(alpha: 0.9))),
      ]),
    );
  }

  Widget _manualBatteryTile(Battery battery) {
    final statusColor = batteryStatusColor(battery);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.black.withValues(alpha: 0.07), width: 0.5)),
      child: Row(children: [
        TapCursor(
          onTap: _isGuest ? () => _openDetail(battery) : null,
          child: Container(
            width: 58, height: 46,
            decoration: BoxDecoration(color: statusColor, borderRadius: BorderRadius.circular(12)),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              FittedBox(fit: BoxFit.scaleDown, child: Text(battery.displayName, maxLines: 1,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.white))),
              if (battery.isInUse)
                const Text('IN USE', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w800, color: Colors.white)),
            ]),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(batteryStatusLabel(battery),
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: statusColor)),
          const SizedBox(height: 2),
          Text(_chargedLabel(battery), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
          if (_showFlags && battery.flags.isNotEmpty) ...[
            const SizedBox(height: 3),
            TapCursor(onTap: () => _openDetail(battery), child: Text(
              'flagged ${battery.flags.length}x, tap to view',
              style: const TextStyle(fontSize: 11, color: redChar),
            )),
          ],
        ])),
        if (!_isGuest) ...[
          TapCursor(onTap: () => _toggleCharging(battery), child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
                color: (battery.isCharging && !battery.isDead) ? greenChar
                    : battery.isCoolingDown ? Colors.blueGrey.withValues(alpha: 0.15) : YellorLight,
                borderRadius: BorderRadius.circular(10)),
            child: Text((battery.isCharging && !battery.isDead) ? 'Charging' : 'Charge',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500,
                    color: (battery.isCharging && !battery.isDead) ? Colors.white
                        : battery.isCoolingDown ? Colors.blueGrey : YellorDark)),
          )),
          const SizedBox(width: 6),
          TapCursor(onTap: () => _toggleInUse(battery), child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(color: battery.isInUse ? redChar : YellorLight,
                borderRadius: BorderRadius.circular(10)),
            child: Text(battery.isInUse ? 'In use' : 'Use', style: TextStyle(fontSize: 12,
                fontWeight: FontWeight.w500, color: battery.isInUse ? Colors.white : YellorDark)),
          )),
          const SizedBox(width: 6),
          TapCursor(onTap: () => _flagWeak(battery), child: Padding(
              padding: const EdgeInsets.all(8),
              child: Icon(Icons.flag_outlined, size: 16, color: Colors.grey[500]))),
          TapCursor(onTap: () => _showBatteryMenu(battery), child: Padding(
              padding: const EdgeInsets.all(8),
              child: Icon(Icons.settings_outlined, size: 18, color: Colors.grey[500]))),
        ],
      ]),
    );
  }



  Widget _suggestionBar() {
    Widget strip(List<Widget> children, {Color color = YellorLight}) => Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration:
              BoxDecoration(color: color, borderRadius: BorderRadius.circular(14)),
          child: Row(children: children),
        );

    if (_loadingRecommendation && _suggestedLabel == null) {
      return strip([
        const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2, color: YellorDark)),
        const SizedBox(width: 10),
        const Text('Picking a battery…',
            style: TextStyle(fontSize: 13, color: YellorDark)),
      ]);
    }

    final label = _suggestedLabel;
    Battery? picked;
    if (label != null) {
      for (final b in _batteries) {
        if (b.label == label) picked = b;
      }
    }

    if (picked != null) {
      final reason = _isGuest
          ? (_teamAuto ? batteryNodeLine(picked) : _chargedLabel(picked))
          : _recommendReason;
      return strip([
        const Icon(Icons.auto_awesome, color: YellorDark, size: 18),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Next up: ${picked.displayName}',
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w700, color: YellorDark)),
            if (reason != null && reason.isNotEmpty)
              Text(reason,
                  style: TextStyle(fontSize: 12, color: Colors.grey[700])),
          ]),
        ),
        if (!_isGuest)
          TapCursor(
            onTap: _askAiRecommendation,
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(Icons.refresh, color: YellorDark, size: 18),
            ),
          ),
      ]);
    }

    if (_isGuest) return const SizedBox.shrink();
    final why = _recommendReason;
    final hasWhy = why != null && why.isNotEmpty;
    return TapCursor(
      onTap: _askAiRecommendation,
      child: strip([
        const Icon(Icons.auto_awesome, color: YellorDark, size: 18),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(hasWhy ? 'No pick yet' : 'Ask AI which battery to use',
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w600, color: YellorDark)),
            if (why != null && why.isNotEmpty)
              Text(why,
                  style: TextStyle(fontSize: 12, color: Colors.grey[700])),
          ]),
        ),
      ]),
    );
  }


  List<Battery> _gridOrder() {
    final list = [..._batteries];
    list.sort((a, b) {
      if (a.nodeConnected != b.nodeConnected) return a.nodeConnected ? -1 : 1;
      return _labelSortKey(a.label).compareTo(_labelSortKey(b.label));
    });
    return list;
  }

  Widget _grid() {
    return LayoutBuilder(builder: (context, c) {
      const gap = 10.0;
      final cols = c.maxWidth >= 720 ? 4 : (c.maxWidth >= 480 ? 3 : 2);
      final w = (c.maxWidth - gap * (cols - 1)) / cols;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [for (final b in _gridOrder()) _tile(b, w)],
      );
    });
  }

  Widget _pill(String text, Color bg, Color fg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(text,
          style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w800, color: fg)),
    );
  }


  Widget? _tileTag(Battery b, bool suggested) {
    if (b.isInUse) return _pill('IN USE', redChar, Colors.white);
    if (!_autoMode) {
      if (b.isDead) {
        return b.isCoolingDown
            ? _pill('COOLING', Colors.blueGrey.withValues(alpha: 0.15), Colors.blueGrey)
            : _pill('DEAD', deadChar.withValues(alpha: 0.15), deadChar);
      }
      if (b.isCharging) {
        return b.isChargingComplete
            ? _pill('READY', greenChar.withValues(alpha: 0.15), greenChar)
            : _pill('CHARGING', Colors.orange.withValues(alpha: 0.18), Colors.deepOrange);
      }
    }
    if (suggested) return _pill('NEXT', Yellor, Colors.black87);
    return null;
  }

  Widget _tile(Battery b, double width) {
    final suggested = _suggestedLabel == b.label;
    final tag = _tileTag(b, suggested);
    final connected = b.nodeConnected;
    return SizedBox(
      width: width,
      child: TapCursor(
        onTap: () => _openDetail(b),
        child: Container(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: suggested ? Yellor : Colors.black.withValues(alpha: 0.07),
              width: suggested ? 2 : 0.5,
            ),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(
              height: 24,
              child: Row(children: [
                if (tag != null) tag,
                const Spacer(),
              ]),
            ),
            const SizedBox(height: 4),
            BatteryIcon(battery: b, height: 58),
            const SizedBox(height: 10),
            Text(b.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(batteryNodeLine(b),
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: connected ? FontWeight.w700 : FontWeight.w400,
                    color: connected ? nodeOnColor : Colors.grey[500])),
          ]),
        ),
      ),
    );
  }

  Widget _legend() {
    Widget item(Color c, String text) => Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.circle, size: 9, color: c),
          const SizedBox(width: 6),
          Text(text, style: TextStyle(fontSize: 12, color: Colors.grey[600])),
        ]);
    return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      item(nodeOnColor, 'Node connected'),
      const SizedBox(width: 18),
      item(nodeOffColor, 'Not connected'),
    ]);
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
