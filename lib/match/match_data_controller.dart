import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../push_notifications.dart';
import 'match_models.dart';


class MyTeam {
  final String teamNumber;

  List<MatchEvent> events = [];
  String? selectedEventKey;

  List<MatchInfo> matches = [];
  Map<String, double> oprs = {};
  Map<String, double> worldOprs = {};
  TeamStatus? myStatus;

  TeamProfile? profile;
  bool loadingProfile = false;

  bool isLoading = false;
  bool loadingEvents = false;
  String? error;

  String pushState = 'unsupported';
  bool pushBusy = false;
  bool showPushHint = false;

  MyTeam(this.teamNumber);

  String get teamKey => 'frc$teamNumber';

  MatchEvent? get selectedEvent =>
      events.where((e) => e.key == selectedEventKey).firstOrNull;

  List<MatchInfo> get myMatches =>
      matches.where((m) => m.hasTeam(teamKey)).toList();

  List<MatchInfo> get upcomingMatches {
    final unplayed = myMatches.where((m) => !m.isPlayed).toList();
    if (unplayed.isEmpty) return unplayed;
    final now = DateTime.now();
    final notOverdue = unplayed.where((m) {
      final t = m.bestTime;
      return t == null || !t.isBefore(now);
    }).toList();
    return notOverdue.isNotEmpty ? notOverdue : unplayed;
  }

  MatchInfo? get nextMatch =>
      upcomingMatches.isEmpty ? null : upcomingMatches.first;

  MatchEvent? get nextUpcomingEvent {
    final now = DateTime.now();
    final upcoming =
        events
            .where((e) => e.endDate == null || !e.endDate!.isBefore(now))
            .toList()
          ..sort(
            (a, b) => (a.startDate ?? DateTime(2100)).compareTo(
              b.startDate ?? DateTime(2100),
            ),
          );
    return upcoming.isEmpty ? null : upcoming.first;
  }


  List<EventTeam> get eventTeams {
    final teams = oprs.entries
        .map((e) => EventTeam(teamKey: e.key, opr: e.value))
        .toList();
    teams.sort((a, b) => b.opr.compareTo(a.opr));
    return teams;
  }
}

class MatchDataController extends ChangeNotifier {
  static const String backendBase = 'https://ridgeboticsapp.onrender.com';

  MyTeam? myTeam;
  final Map<String, Future<List<TeamStats>>> _eventStatsFutures = {};
  final Map<String, Future<List<EventTeamInfo>>> _eventTeamsFutures = {};
  final Map<String, Future<List<MatchInfo>>> _eventMatchesFutures = {};
  final Map<String, Future<List<EventAlliance>>> _eventAlliancesFutures = {};
  Future<List<TeamStats>>? _worldStatsFuture;

  double winProbScale = 20;
  final Map<String, Future<Map<String, double>>> _liveRatingFutures = {};
  final Map<String, DateTime> _liveRatingTimes = {};
  final Expando<double> _meanCache = Expando<double>();
  final Expando<int> _meanCacheSize = Expando<int>();

  bool isLoading = true;

 
  static const String _fakeTeamNumber = '-4388';
  static const String _fakeEventKey = 'faketest2026';

  Future<void> _cacheRawJson(String key, Object rawJson) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('cache_$key', jsonEncode(rawJson));
      await prefs.setInt(
        'cache_${key}_time',
        DateTime.now().millisecondsSinceEpoch,
      );
    } catch (_) {

    }
  }

  Future<T?> _readCachedJson<T>(
    String key,
    T Function(dynamic decoded) parse,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('cache_$key');
      if (raw == null) return null;
      return parse(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }


  Future<DateTime?> cacheTimestamp(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ms = prefs.getInt('cache_${key}_time');
      return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
    } catch (_) {
      return null;
    }
  }

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString('my_team_number');

    if (stored == null || stored.isEmpty) {
      isLoading = false;
      notifyListeners();
      return;
    }

    myTeam = MyTeam(stored);
    notifyListeners();

    await bootstrap(myTeam!);
    isLoading = false;
    notifyListeners();
  }

  Future<void> setMyTeam(String teamNumber) async {
    final number = teamNumber.trim();
    if (number.isEmpty) return;

    myTeam = MyTeam(number);
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('my_team_number', number);

    await bootstrap(myTeam!);
    notifyListeners();
  }

  Future<void> clearMyTeam() async {
    myTeam = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('my_team_number');
    notifyListeners();
  }

  Future<void> bootstrap(MyTeam t) async {
    await loadEventsFor(t, silent: true);
    unawaited(loadTeamProfileFor(t));

    if (t.events.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    final storedEventKey = prefs.getString('my_team_event_${t.teamNumber}');
    final storedEventStillValid =
        storedEventKey != null && t.events.any((e) => e.key == storedEventKey);

    t.selectedEventKey = storedEventStillValid
        ? storedEventKey
        : t.events
              .firstWhere(
                (e) => e.isLiveNow,
                orElse: () => t.nextUpcomingEvent ?? t.events.last,
              )
              .key;

    await loadEventDataFor(t);
    await refreshPushState(t);
  }

  Future<void> setSelectedEvent(String eventKey) async {
    final t = myTeam;
    if (t == null) return;
    t.selectedEventKey = eventKey;
    notifyListeners();

    await loadEventDataFor(t);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('my_team_event_${t.teamNumber}', eventKey);

    await refreshPushState(t);
    notifyListeners();
  }

  Future<void> refresh() async {
    final t = myTeam;
    if (t == null) return;
    await loadEventDataFor(t);
    await loadTeamProfileFor(t);
  }

  Future<void> refreshEvents() async {
    final t = myTeam;
    if (t == null) return;
    await loadEventsFor(t);
  }

  Future<void> loadEventsFor(MyTeam t, {bool silent = false}) async {
    t.loadingEvents = true;
    t.error = null;
    if (!silent) notifyListeners();

    final cacheKey = 'events_${t.teamNumber}';

    try {
      final year = DateTime.now().year;
      final uri = Uri.parse(
        '$backendBase/match/events?teamNumber=${t.teamNumber}&year=$year',
      );
      final res = await http.get(uri).timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) {
        throw StateError('Could not load events for that team');
      }
      final list = jsonDecode(res.body) as List<dynamic>;
      await _cacheRawJson(cacheKey, list);
      final loaded = list
          .map((e) => MatchEvent.fromJson(e as Map<String, dynamic>))
          .toList();
      loaded.sort(
        (a, b) => (a.startDate ?? DateTime(2000)).compareTo(
          b.startDate ?? DateTime(2000),
        ),
      );
      t.events = loaded;
      t.error = loaded.isEmpty
          ? 'No events found for team ${t.teamNumber} this season'
          : null;
      t.loadingEvents = false;
      notifyListeners();
    } catch (_) {
      final cached = await _readCachedJson<List<MatchEvent>>(cacheKey, (decoded) {
        final loaded = (decoded as List<dynamic>)
            .map((e) => MatchEvent.fromJson(e as Map<String, dynamic>))
            .toList();
        loaded.sort(
          (a, b) => (a.startDate ?? DateTime(2000)).compareTo(
            b.startDate ?? DateTime(2000),
          ),
        );
        return loaded;
      });

      if (cached != null && cached.isNotEmpty) {
        final cachedAt = await cacheTimestamp(cacheKey);
        t.events = cached;
        t.error = cachedAt == null
            ? 'Showing saved events. Could not connect'
            : 'Showing events from ${_friendlyAgo(cachedAt)}. Could not connect';
      } else {
        t.error = 'Could not connect, try again';
      }
      t.loadingEvents = false;
      notifyListeners();
    }
  }

  String _friendlyAgo(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours} hr ago';
    return '${diff.inDays} day${diff.inDays == 1 ? '' : 's'} ago';
  }

  Future<void> loadEventDataFor(MyTeam t) async {
    if (t.selectedEventKey == null) return;
    t.isLoading = true;
    t.error = null;
    notifyListeners();

    final worldStatsFuture = loadWorldTeamStats().catchError(
      (_) => <TeamStats>[],
    );
    final liveRatingsFuture = loadLiveEventRatings(
      t.selectedEventKey!,
    ).catchError((_) => <String, double>{});

    try {
      final uri = Uri.parse(
        '$backendBase/match/data?teamNumber=${t.teamNumber}&eventKey=${t.selectedEventKey}',
      );
      final res = await http.get(uri).timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) {
        t.error = 'Could not load match data';
        t.isLoading = false;
        notifyListeners();
        return;
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;

      final matchesJson = data['matches'] as List<dynamic>? ?? [];
      final loadedMatches = matchesJson
          .map((m) => MatchInfo.fromJson(m as Map<String, dynamic>))
          .toList();
      loadedMatches.sort((a, b) {
        final at = a.bestTime;
        final bt = b.bestTime;
        if (at == null && bt == null) {
          return a.matchNumber.compareTo(b.matchNumber);
        }
        if (at == null) {
          return 1;
        }
        if (bt == null) {
          return -1;
        }
        return at.compareTo(bt);
      });

      final oprsJson = data['oprs'] as Map<String, dynamic>? ?? {};
      final loadedOprs = oprsJson.map(
        (k, v) => MapEntry(k, (v as num).toDouble()),
      );
      final worldStats = await worldStatsFuture;
      final liveRatings = await liveRatingsFuture;

      t.matches = loadedMatches;
      t.oprs = loadedOprs;
      t.worldOprs = liveRatings.isNotEmpty
          ? liveRatings
          : {
              for (final s in worldStats)
                if (s.opr != null) 'frc${s.teamNumber}': s.opr!,
            };
      t.myStatus = TeamStatus.fromJson(data['status'] as Map<String, dynamic>?);
      t.isLoading = false;
      notifyListeners();
    } catch (_) {
      t.error = 'Could not connect, try again';
      t.isLoading = false;
      notifyListeners();
    }
  }


  Future<void> loadTeamProfileFor(MyTeam t) async {
    t.loadingProfile = true;
    notifyListeners();
    t.profile = await loadTeamProfile(t.teamNumber);
    t.loadingProfile = false;
    notifyListeners();
  }

  Future<TeamProfile> loadTeamProfile(String teamNumber) async {
    try {
      final uri = Uri.parse('$backendBase/team/profile?teamNumber=$teamNumber');
      final res = await http.get(uri).timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) {
        return const TeamProfile(pastEvents: [], awards: []);
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      return TeamProfile.fromJson(data);
    } catch (_) {
      return const TeamProfile(pastEvents: [], awards: []);
    }
  }


  double? winProbabilityFor(MyTeam t, MatchInfo m) {
    final onRed = m.teamOnRed(t.teamKey);
    final myAlliance = onRed ? m.redTeams : m.blueTeams;
    final oppAlliance = onRed ? m.blueTeams : m.redTeams;
    return winProbabilityBetween(t, myAlliance, oppAlliance);
  }


  double? winProbabilityBetween(
    MyTeam t,
    List<String> allianceA,
    List<String> allianceB,
  ) => winProbabilityBetweenOprs(t.worldOprs, allianceA, allianceB);

  double? winProbabilityBetweenOprs(
    Map<String, double> oprs,
    List<String> allianceA,
    List<String> allianceB,
  ) {
    if (oprs.isEmpty) return null;
    double sum(List<String> teamKeys) =>
        teamKeys.fold(0.0, (s, k) => s + ratingOf(oprs, k));
    final a = sum(allianceA);
    final b = sum(allianceB);
    if (a == 0 && b == 0) return null;
    return winProbabilityFromTotals(a, b);
  }

  double winProbabilityFromTotals(double a, double b) {
    final p = 1 / (1 + math.exp(-(a - b) / winProbScale));
    return p.clamp(0.01, 0.99);
  }

  double ratingOf(Map<String, double> ratings, String teamKey) =>
      ratings[teamKey] ?? _meanRating(ratings);

  double _meanRating(Map<String, double> ratings) {
    if (ratings.isEmpty) return 0;
    final cached = _meanCache[ratings];
    if (cached != null && _meanCacheSize[ratings] == ratings.length) return cached;
    final mean = ratings.values.fold(0.0, (s, v) => s + v) / ratings.length;
    _meanCache[ratings] = mean;
    _meanCacheSize[ratings] = ratings.length;
    return mean;
  }

  List<String> suggestionsFor(
    MyTeam t,
    MatchInfo m,
    Duration timeUntil,
    double? winProb,
  ) {
    final tips = <String>[];
    final onRed = m.teamOnRed(t.teamKey);
    final myAllianceKeys = onRed ? m.redTeams : m.blueTeams;
    final oppAllianceKeys = onRed ? m.blueTeams : m.redTeams;
    double allianceScore(List<String> keys) =>
        keys.fold(0.0, (s, k) => s + ratingOf(t.worldOprs, k));
    final myScore = allianceScore(myAllianceKeys);
    final oppScore = allianceScore(oppAllianceKeys);
    if (t.worldOprs.isNotEmpty && (myScore > 0 || oppScore > 0)) {
      tips.add('My alliance: ~${myScore.toStringAsFixed(1)} estimated points');
      tips.add('Their alliance: ~${oppScore.toStringAsFixed(1)} estimated points');
    } else {
      tips.add(
        'Not enough ranking data yet to estimate this matchup. Check back once more matches are played.',
      );
    }
    String withPoints(String key) {
      final number = key.replaceFirst('frc', '');
      final opr = t.worldOprs[key];
      return opr != null ? '$number (${opr.toStringAsFixed(1)} points)' : number;
    }

    final partners = myAllianceKeys
        .where((k) => k != t.teamKey)
        .map(withPoints)
        .join(', ');
    final opponents = oppAllianceKeys.map(withPoints).join(', ');
    if (partners.isNotEmpty) tips.add('Alliance partners: $partners');
    tips.add('Opponents: $opponents');
    return tips;
  }

  String formatDuration(Duration d) {
    if (d.isNegative) return 'starting now';
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    if (h > 0) return '${h}h ${m}m';
    if (m > 0) return '${m}m ${s}s';
    return '${s}s';
  }


  Future<List<MatchEvent>> loadGlobalEvents() async {
    final now = DateTime.now();
    final years = {now.year - 1, now.year, now.year + 1};
    final all = <MatchEvent>[];

    Future<void> fetchYear(int y) async {
      try {
        final uri = Uri.parse('$backendBase/events?year=$y');
        final res = await http.get(uri).timeout(const Duration(seconds: 20));
        if (res.statusCode == 200) {
          final list = jsonDecode(res.body) as List<dynamic>;
          all.addAll(
            list.map((e) => MatchEvent.fromJson(e as Map<String, dynamic>)),
          );
        } else {
          debugPrint(
            'loadGlobalEvents: /events?year=$y returned ${res.statusCode}',
          );
        }
      } catch (e) {
        debugPrint('loadGlobalEvents: failed to load year $y ($e)');
      }
    }

    await Future.wait(years.map(fetchYear));

    final from = now.subtract(const Duration(days: 90));
    final to = now.add(const Duration(days: 90));
    final inRange = all.where((e) {
      final s = e.startDate;
      final en = e.endDate ?? s;
      if (s == null || en == null) return false;
      return !en.isBefore(from) && !s.isAfter(to);
    }).toList();

    if (myTeam?.teamNumber == _fakeTeamNumber &&
        !inRange.any((e) => e.key == _fakeEventKey)) {
      try {
        final uri = Uri.parse(
          '$backendBase/match/events?teamNumber=$_fakeTeamNumber&year=${now.year}',
        );
        final res = await http.get(uri).timeout(const Duration(seconds: 15));
        if (res.statusCode == 200) {
          final list = jsonDecode(res.body) as List<dynamic>;
          inRange.addAll(
            list.map((e) => MatchEvent.fromJson(e as Map<String, dynamic>)),
          );
        }
      } catch (e) {

        debugPrint('loadGlobalEvents: failed to load fake test event ($e)');
      }
    }

    inRange.sort(
      (a, b) => (a.startDate ?? DateTime(2100)).compareTo(
        b.startDate ?? DateTime(2100),
      ),
    );
    return inRange;
  }


  Future<List<String>> loadRoster(String teamNumber, String eventKey) async {
    try {
      final uri = Uri.parse(
        '$backendBase/event/roster?teamNumber=$teamNumber&eventKey=$eventKey',
      );
      final res = await http.get(uri).timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return [];
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      return (data['people'] as List<dynamic>? ?? []).cast<String>();
    } catch (_) {
      return [];
    }
  }

  Future<bool> addToRoster(
    String teamNumber,
    String passcode,
    String eventKey,
    String name,
  ) async {
    try {
      final uri = Uri.parse('$backendBase/event/roster/add');
      final res = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'teamNumber': teamNumber,
              'passcode': passcode,
              'eventKey': eventKey,
              'name': name,
            }),
          )
          .timeout(const Duration(seconds: 15));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<bool> removeFromRoster(
    String teamNumber,
    String passcode,
    String eventKey,
    String name,
  ) async {
    try {
      final uri = Uri.parse('$backendBase/event/roster/remove');
      final res = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'teamNumber': teamNumber,
              'passcode': passcode,
              'eventKey': eventKey,
              'name': name,
            }),
          )
          .timeout(const Duration(seconds: 15));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  void evictEventTeamsCache(String eventKey) => _eventTeamsFutures.remove(eventKey);
  void evictEventStatsCache(String eventKey) => _eventStatsFutures.remove(eventKey);
  void evictEventMatchesCache(String eventKey) => _eventMatchesFutures.remove(eventKey);
  void evictEventAlliancesCache(String eventKey) => _eventAlliancesFutures.remove(eventKey);


  Future<List<EventAlliance>> loadEventAlliances(String eventKey, {bool forceRefresh = false}) {
    if (forceRefresh) _eventAlliancesFutures.remove(eventKey);
    return _eventAlliancesFutures.putIfAbsent(eventKey, () async {
      try {
        final uri = Uri.parse('$backendBase/event/alliances?eventKey=$eventKey');
        final res = await http.get(uri).timeout(const Duration(seconds: 20));
        if (res.statusCode != 200) {
          _eventAlliancesFutures.remove(eventKey);
          return [];
        }
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final list = data['alliances'] as List<dynamic>? ?? [];
        final alliances = list
            .map((a) => EventAlliance.fromJson(a as Map<String, dynamic>))
            .toList();
        if (alliances.isEmpty) _eventAlliancesFutures.remove(eventKey);
        return alliances;
      } catch (_) {
        _eventAlliancesFutures.remove(eventKey);
        return [];
      }
    });
  }


  Future<List<MatchInfo>> loadEventMatches(String eventKey, {bool forceRefresh = false}) {
    if (forceRefresh) _eventMatchesFutures.remove(eventKey);
    return _eventMatchesFutures.putIfAbsent(eventKey, () async {
      try {
        final uri = Uri.parse('$backendBase/event/matches?eventKey=$eventKey');
        final res = await http.get(uri).timeout(const Duration(seconds: 20));
        if (res.statusCode != 200) {
          _eventMatchesFutures.remove(eventKey);
          return [];
        }
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final list = data['matches'] as List<dynamic>? ?? [];
        final matches = list
            .map((m) => MatchInfo.fromJson(m as Map<String, dynamic>))
            .toList();
        matches.sort((a, b) {
          final at = a.bestTime;
          final bt = b.bestTime;
          if (at == null && bt == null) return a.matchNumber.compareTo(b.matchNumber);
          if (at == null) return 1;
          if (bt == null) return -1;
          return at.compareTo(bt);
        });
        if (matches.isEmpty) _eventMatchesFutures.remove(eventKey);
        return matches;
      } catch (_) {
        _eventMatchesFutures.remove(eventKey);
        return [];
      }
    });
  }

  Future<List<EventTeamInfo>> loadEventTeams(String eventKey, {bool forceRefresh = false}) {
    if (forceRefresh) _eventTeamsFutures.remove(eventKey);
    return _eventTeamsFutures.putIfAbsent(eventKey, () async {
      try {
        final uri = Uri.parse('$backendBase/event/teams?eventKey=$eventKey');
        
        final res = await http
            .get(uri)
            .timeout(const Duration(seconds: 15))
            .timeout(const Duration(seconds: 18));
        if (res.statusCode != 200) {
          _eventTeamsFutures.remove(eventKey);
          return [];
        }
        final list = jsonDecode(res.body) as List<dynamic>;
        final teams = list
            .map((t) => EventTeamInfo.fromJson(t as Map<String, dynamic>))
            .toList();
        if (teams.isEmpty) _eventTeamsFutures.remove(eventKey);
        return teams;
      } catch (_) {
        _eventTeamsFutures.remove(eventKey);
        return [];
      }
    });
  }


  Future<List<TeamStats>> loadEventTeamStats({bool forceRefresh = false}) {
    final eventKey = myTeam?.selectedEventKey;
    if (eventKey == null) {
      return Future.error(
        StateError('Choose an event before viewing team stats.'),
      );
    }
    return loadEventTeamStatsFor(eventKey, forceRefresh: forceRefresh);
  }


  Future<List<TeamStats>> loadEventTeamStatsFor(String eventKey, {bool forceRefresh = false}) {
    if (forceRefresh) _eventStatsFutures.remove(eventKey);
    final cacheKey = 'event_stats_$eventKey';
    return _eventStatsFutures.putIfAbsent(eventKey, () async {
      List<TeamStats> parseAndSort(List<dynamic> rawList) {
        final loaded = rawList
            .map((t) => TeamStats.fromJson(t as Map<String, dynamic>))
            .toList();
        loaded.sort(
          (a, b) => (a.rank == 0 ? 1 << 30 : a.rank).compareTo(
            b.rank == 0 ? 1 << 30 : b.rank,
          ),
        );
        return loaded;
      }

      try {
        final uri = Uri.parse('$backendBase/event/stats?eventKey=$eventKey');
        final res = await http.get(uri).timeout(const Duration(seconds: 15));
        if (res.statusCode != 200) {
          String message = 'Could not load event stats';
          try {
            message =
                (jsonDecode(res.body) as Map<String, dynamic>)['error']
                    as String? ??
                message;
          } catch (_) {}
          throw StateError(message);
        }
        final rawList = jsonDecode(res.body) as List<dynamic>;
        await _cacheRawJson(cacheKey, rawList);
        return parseAndSort(rawList);
      } catch (e) {
        _eventStatsFutures.remove(eventKey);
        final cached = await _readCachedJson<List<TeamStats>>(
          cacheKey,
          (decoded) => parseAndSort(decoded as List<dynamic>),
        );
        if (cached != null && cached.isNotEmpty) return cached;
        rethrow;
      }
    });
  }

  Future<Map<String, double>> loadLiveEventRatings(
    String eventKey, {
    bool forceRefresh = false,
  }) {
    final at = _liveRatingTimes[eventKey];
    final fresh = at != null &&
        DateTime.now().difference(at) < const Duration(seconds: 45);
    if (!forceRefresh && fresh && _liveRatingFutures[eventKey] != null) {
      return _liveRatingFutures[eventKey]!;
    }
    final future = () async {
      final uri = Uri.parse('$backendBase/event/ratings?eventKey=$eventKey');
      final res = await http.get(uri).timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) throw StateError('ratings unavailable');
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final scale = (data['scale'] as num?)?.toDouble();
      if (scale != null && scale > 0) winProbScale = scale;
      final raw = data['ratings'] as Map<String, dynamic>? ?? {};
      return raw.map((k, v) => MapEntry(k, (v as num).toDouble()));
    }();
    _liveRatingFutures[eventKey] = future;
    _liveRatingTimes[eventKey] = DateTime.now();
    future.catchError((_) {
      _liveRatingFutures.remove(eventKey);
      _liveRatingTimes.remove(eventKey);
      return <String, double>{};
    });
    return future;
  }

  Future<List<TeamStats>> loadWorldTeamStats({bool forceRefresh = false}) {
    if (forceRefresh) _worldStatsFuture = null;
    const cacheKey = 'world_stats';
    return _worldStatsFuture ??= () async {
      List<TeamStats> parse(List<dynamic> rawList) => rawList
          .map((t) => TeamStats.fromJson(t as Map<String, dynamic>))
          .toList();

      try {
        final uri = Uri.parse('$backendBase/world/stats?year=${DateTime.now().year}');
        final res = await http.get(uri).timeout(const Duration(seconds: 20));
        if (res.statusCode != 200) {
          String message = 'World ratings are still being calculated';
          try { message = (jsonDecode(res.body) as Map<String, dynamic>)['message'] as String? ?? message; } catch (_) {}
          throw StateError(message);
        }
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final scale = (data['winProbScale'] as num?)?.toDouble();
        if (scale != null && scale > 0) winProbScale = scale;
        final rawList = data['teams'] as List<dynamic>? ?? [];
        await _cacheRawJson(cacheKey, rawList);
        return parse(rawList);
      } catch (e) {
        _worldStatsFuture = null;
        final cached = await _readCachedJson<List<TeamStats>>(
          cacheKey,
          (decoded) => parse(decoded as List<dynamic>),
        );
        if (cached != null && cached.isNotEmpty) return cached;
        rethrow;
      }
    }();
  }

  // The Accuracy tab is only offered when signed in as the test team.
  bool get canSeeAccuracy => myTeam?.teamNumber == _fakeTeamNumber;

  Future<ModelAccuracy> loadModelAccuracy() async {
    final uri = Uri.parse('$backendBase/world/accuracy?year=${DateTime.now().year}');
    final res = await http.get(uri).timeout(const Duration(seconds: 25));
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode == 202) {
      throw StateError(
        data['message'] as String? ??
            'Accuracy is being calculated. Try again in a minute or two.',
      );
    }
    if (res.statusCode != 200) {
      throw StateError(
        data['error'] as String? ?? 'Could not load model accuracy',
      );
    }
    return ModelAccuracy.fromJson(data);
  }

  Future<({TeamStats team, List<TeamStats> nearby})> loadWorldTeamStat(String teamNumber) async {
    final uri = Uri.parse('$backendBase/world/team/$teamNumber');
    final res = await http.get(uri).timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) throw StateError('Team rating is not available yet');
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return (
      team: TeamStats.fromJson(data['team'] as Map<String, dynamic>),
      nearby: (data['nearby'] as List<dynamic>? ?? [])
          .map((item) => TeamStats.fromJson(item as Map<String, dynamic>))
          .toList(),
    );
  }


  Future<void> refreshPushState(MyTeam t) async {
    t.pushState = await PushNotifications.subscriptionState();
    notifyListeners();
  }

  Future<String> togglePush() async {
    final t = myTeam;
    if (t == null || t.pushBusy || t.selectedEventKey == null) {
      return 'no-event';
    }
    t.pushBusy = true;
    notifyListeners();

    final wasSubscribed = t.pushState == 'subscribed';
    final outcome = wasSubscribed
        ? (await PushNotifications.unsubscribe()
              ? 'unsubscribed'
              : 'unsubscribe-failed')
        : await PushNotifications.subscribe(t.teamNumber, t.selectedEventKey!);

    await refreshPushState(t);
    t.pushBusy = false;
    notifyListeners();
    return outcome;
  }

  void showPushButtonHint() {
    final t = myTeam;
    if (t == null) return;
    t.showPushHint = true;
    notifyListeners();
  }

  void dismissPushButtonHint() {
    final t = myTeam;
    if (t == null || !t.showPushHint) return;
    t.showPushHint = false;
    notifyListeners();
  }
}

extension FirstOrNullExtension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}