class MatchInfo {
  final String key;
  final String compLevel;
  final int matchNumber;
  final int setNumber;
  final DateTime? predictedTime;
  final DateTime? actualTime;
  final List<String> redTeams;
  final List<String> blueTeams;
  final int? redScore;
  final int? blueScore;

  const MatchInfo({
    required this.key,
    required this.compLevel,
    required this.matchNumber,
    required this.setNumber,
    required this.predictedTime,
    required this.actualTime,
    required this.redTeams,
    required this.blueTeams,
    required this.redScore,
    required this.blueScore,
  });

  bool get isPlayed =>
      redScore != null &&
      redScore! >= 0 &&
      blueScore != null &&
      blueScore! >= 0;

  bool teamOnRed(String teamKey) => redTeams.contains(teamKey);
  bool teamOnBlue(String teamKey) => blueTeams.contains(teamKey);
  bool hasTeam(String teamKey) => teamOnRed(teamKey) || teamOnBlue(teamKey);


  DateTime? get bestTime => predictedTime ?? actualTime;

  String get label {
    switch (compLevel) {
      case 'p':
        return 'Practice $matchNumber';
      case 'qm':
        return 'Quals $matchNumber';
      case 'qf':
        return 'Quarters $setNumber-$matchNumber';
      case 'sf':
        return 'Semis $setNumber-$matchNumber';
      case 'f':
        return 'Finals $matchNumber';
      default:
        return '$compLevel $matchNumber';
    }
  }

  factory MatchInfo.fromJson(Map<String, dynamic> json) {
    final alliances = json['alliances'] as Map<String, dynamic>? ?? {};
    final red = alliances['red'] as Map<String, dynamic>? ?? {};
    final blue = alliances['blue'] as Map<String, dynamic>? ?? {};
    final predicted = json['predicted_time'] as int?;
    final actual = json['actual_time'] as int?;
    return MatchInfo(
      key: json['key'] as String? ?? '',
      compLevel: json['comp_level'] as String? ?? 'qm',
      matchNumber: json['match_number'] as int? ?? 0,
      setNumber: json['set_number'] as int? ?? 1,
      predictedTime: predicted != null
          ? DateTime.fromMillisecondsSinceEpoch(predicted * 1000)
          : null,
      actualTime: actual != null
          ? DateTime.fromMillisecondsSinceEpoch(actual * 1000)
          : null,
      redTeams: (red['team_keys'] as List<dynamic>? ?? []).cast<String>(),
      blueTeams: (blue['team_keys'] as List<dynamic>? ?? []).cast<String>(),
      redScore: red['score'] as int?,
      blueScore: blue['score'] as int?,
    );
  }
}

class TeamStatus {
  final int? rank;
  final int? numTeams;
  final int wins;
  final int losses;
  final int ties;

  const TeamStatus({
    this.rank,
    this.numTeams,
    required this.wins,
    required this.losses,
    required this.ties,
  });

  factory TeamStatus.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const TeamStatus(wins: 0, losses: 0, ties: 0);
    final qual = json['qual'] as Map<String, dynamic>?;
    final ranking = qual?['ranking'] as Map<String, dynamic>?;
    final record = ranking?['record'] as Map<String, dynamic>?;
    return TeamStatus(
      rank: ranking?['rank'] as int?,
      numTeams: qual?['num_teams'] as int?,
      wins: record?['wins'] as int? ?? 0,
      losses: record?['losses'] as int? ?? 0,
      ties: record?['ties'] as int? ?? 0,
    );
  }
}


class EventAlliance {
  final List<String> picks;
  final bool won;
  final String? level;

  const EventAlliance({required this.picks, required this.won, this.level});


  bool get isRunnerUp => level == 'f' && !won;

  factory EventAlliance.fromJson(Map<String, dynamic> json) {
    final status = json['status'] as Map<String, dynamic>?;
    return EventAlliance(
      picks: (json['picks'] as List<dynamic>? ?? []).cast<String>(),
      won: (status?['status'] as String?) == 'won',
      level: status?['level'] as String?,
    );
  }
}

class MatchEvent {
  final String key;
  final String name;
  final DateTime? startDate;
  final DateTime? endDate;
  final String location;

  const MatchEvent({
    required this.key,
    required this.name,
    this.startDate,
    this.endDate,
    this.location = '',
  });

  factory MatchEvent.fromJson(Map<String, dynamic> json) {
    return MatchEvent(
      key: json['key'] as String? ?? '',
      name: json['name'] as String? ?? json['key'] as String? ?? 'Event',
      startDate: json['start_date'] != null
          ? DateTime.tryParse(json['start_date'])
          : null,
      endDate: json['end_date'] != null
          ? DateTime.tryParse(json['end_date'])
          : null,
      location: [json['city'], json['state_prov'], json['country']]
          .whereType<String>()
          .where((part) => part.isNotEmpty)
          .join(', '),
    );
  }

  bool get isLiveNow {
    final now = DateTime.now();
    if (startDate == null || endDate == null) return false;
    final end = endDate!.add(const Duration(days: 1));
    return now.isAfter(startDate!.subtract(const Duration(days: 1))) &&
        now.isBefore(end);
  }
}

class EventTeam {
  final String teamKey;
  final double opr;

  const EventTeam({required this.teamKey, required this.opr});

  String get teamNumber => teamKey.replaceFirst('frc', '');


  @override
  bool operator ==(Object other) =>
      other is EventTeam && other.teamKey == teamKey;

  @override
  int get hashCode => teamKey.hashCode;
}


class EventTeamInfo {
  final String teamNumber;
  final String name;

  const EventTeamInfo({required this.teamNumber, required this.name});

  factory EventTeamInfo.fromJson(Map<String, dynamic> json) {
    final number = json['team_number']?.toString() ?? '';
    return EventTeamInfo(
      teamNumber: number,
      name: json['name'] as String? ?? 'Team $number',
    );
  }
}

class TeamStats {
  final String teamNumber;
  final String name;
  final double? opr;
  final int rank;
  final int wins;
  final int losses;
  final int ties;

  const TeamStats({
    required this.teamNumber,
    required this.name,
    required this.opr,
    required this.rank,
    required this.wins,
    required this.losses,
    required this.ties,
  });

  factory TeamStats.fromJson(Map<String, dynamic> json) {
    double? asDoubleOrNull(dynamic v) => (v as num?)?.toDouble();
    final number = json['team_number']?.toString() ?? '';
    return TeamStats(
      teamNumber: number,
      name: json['name'] as String? ?? 'Team $number',
      opr: asDoubleOrNull(json['opr']),
      rank: json['rank'] as int? ?? 0,
      wins: json['wins'] as int? ?? 0,
      losses: json['losses'] as int? ?? 0,
      ties: json['ties'] as int? ?? 0,
    );
  }
}

class TeamAward {
  final String name;
  final String eventName;
  final int year;

  const TeamAward({
    required this.name,
    required this.eventName,
    required this.year,
  });

  factory TeamAward.fromJson(Map<String, dynamic> json) {
    return TeamAward(
      name: json['name'] as String? ?? 'Award',
      eventName: json['event_name'] as String? ?? '',
      year: json['year'] as int? ?? 0,
    );
  }
}

class PastEventResult {
  final String eventKey;
  final String eventName;
  final int year;
  final int? rank;
  final int? numTeams;
  final List<String> awards;

  const PastEventResult({
    required this.eventKey,
    required this.eventName,
    required this.year,
    this.rank,
    this.numTeams,
    this.awards = const [],
  });

  factory PastEventResult.fromJson(Map<String, dynamic> json) {
    return PastEventResult(
      eventKey: json['event_key'] as String? ?? '',
      eventName:
          json['event_name'] as String? ??
          json['event_key'] as String? ??
          'Event',
      year: json['year'] as int? ?? 0,
      rank: json['rank'] as int?,
      numTeams: json['num_teams'] as int?,
      awards: (json['awards'] as List<dynamic>? ?? []).cast<String>(),
    );
  }
}

class TeamProfile {
  final String? teamName;
  final int? rookieYear;
  final int? worldRank;
  final List<PastEventResult> pastEvents;
  final List<TeamAward> awards;

  const TeamProfile({
    this.teamName,
    this.rookieYear,
    this.worldRank,
    required this.pastEvents,
    required this.awards,
  });

  factory TeamProfile.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const TeamProfile(pastEvents: [], awards: []);
    final events =
        (json['events'] as List<dynamic>? ?? [])
            .map((e) => PastEventResult.fromJson(e as Map<String, dynamic>))
            .toList()
          ..sort((a, b) => b.year.compareTo(a.year));
    final awards = (json['awards'] as List<dynamic>? ?? [])
        .map((a) => TeamAward.fromJson(a as Map<String, dynamic>))
        .toList()
      ..sort((a, b) => b.year.compareTo(a.year));
    return TeamProfile(
      teamName: json['team_name'] as String?,
      rookieYear: json['rookie_year'] as int?,
      worldRank: json['world_rank'] as int?,
      pastEvents: events,
      awards: awards,
    );
  }

  int? get yearsCompeting {
    if (rookieYear == null) return null;
    return DateTime.now().year - rookieYear! + 1;
  }
}

class ModelAccuracy {
  final int games;
  final int correct;
  final int eventsCounted;
  final double? accuracyPct;
  final double? avgMarginError;
  final DateTime? refreshedAt;

  const ModelAccuracy({
    required this.games,
    required this.correct,
    required this.eventsCounted,
    required this.accuracyPct,
    required this.avgMarginError,
    required this.refreshedAt,
  });

  factory ModelAccuracy.fromJson(Map<String, dynamic> json) {
    return ModelAccuracy(
      games: (json['games'] as num?)?.toInt() ?? 0,
      correct: (json['correct'] as num?)?.toInt() ?? 0,
      eventsCounted: (json['eventsCounted'] as num?)?.toInt() ?? 0,
      accuracyPct: (json['accuracyPct'] as num?)?.toDouble(),
      avgMarginError: (json['avgMarginError'] as num?)?.toDouble(),
      refreshedAt: json['refreshedAt'] != null
          ? DateTime.tryParse(json['refreshedAt'] as String)
          : null,
    );
  }
}