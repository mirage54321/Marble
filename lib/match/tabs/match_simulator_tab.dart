import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../match_models.dart';
import '../match_scope.dart';
import '../match_theme.dart';

class MatchSimulatorTab extends StatefulWidget {
  const MatchSimulatorTab({super.key});

  @override
  State<MatchSimulatorTab> createState() => _MatchSimulatorTabState();
}

class _MatchSimulatorTabState extends State<MatchSimulatorTab>
    with SingleTickerProviderStateMixin {
  final List<TextEditingController> _redCtrls = List.generate(
    3,
    (_) => TextEditingController(),
  );
  final List<TextEditingController> _blueCtrls = List.generate(
    3,
    (_) => TextEditingController(),
  );

  final List<Timer?> _redDebounce = List.generate(3, (_) => null);
  final List<Timer?> _blueDebounce = List.generate(3, (_) => null);


  final Map<String, TeamStats?> _cache = {};
  final Set<String> _loading = {};
  final Set<String> _unavailable = {};

  late final AnimationController _idleController = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 8),
  )..repeat();

  @override
  void dispose() {
    for (final c in [..._redCtrls, ..._blueCtrls]) {
      c.dispose();
    }
    for (final t in [..._redDebounce, ..._blueDebounce]) {
      t?.cancel();
    }
    _idleController.dispose();
    super.dispose();
  }

  TeamStats? _resolved(String number) => _cache[number];

  void _onChanged(int i, bool isRed) {
    setState(() {});

    final ctrl = isRed ? _redCtrls[i] : _blueCtrls[i];
    final debounceList = isRed ? _redDebounce : _blueDebounce;
    debounceList[i]?.cancel();

    final number = ctrl.text.trim();
    if (number.isEmpty || _cache.containsKey(number)) return;

    debounceList[i] = Timer(
      const Duration(milliseconds: 450),
      () => _lookup(number),
    );
  }

  Future<void> _lookup(String number) async {
    if (_cache.containsKey(number) || _loading.contains(number)) return;
    setState(() => _loading.add(number));

    try {
      final stats = await MatchScope.of(context).loadWorldTeamStats();
      final team = stats.where((team) => team.teamNumber == number).firstOrNull;
      if (!mounted) return;
      setState(() {
        _loading.remove(number);
        _cache[number] = team;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading.remove(number);
        _unavailable.add(number);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final red = _redCtrls
        .map((c) => _resolved(c.text.trim()))
        .whereType<TeamStats>()
        .toList()..sort((a, b) => (b.opr ?? 0).compareTo(a.opr ?? 0));
    final blue = _blueCtrls
        .map((c) => _resolved(c.text.trim()))
        .whereType<TeamStats>()
        .toList()..sort((a, b) => (b.opr ?? 0).compareTo(a.opr ?? 0));
    final redScore = red.fold(0.0, (s, t) => s + (t.opr ?? 0));
    final blueScore = blue.fold(0.0, (s, t) => s + (t.opr ?? 0));
    final showResult = red.isNotEmpty || blue.isNotEmpty;
    final winProb = (redScore + blueScore) == 0
        ? null
        : MatchScope.of(context).winProbabilityFromTotals(redScore, blueScore);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 90),
      children: [
        const Text(
          'Matchup Simulator',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        Text(
          'Add team numbers to place robots on the field and compare World Ratings',
          style: TextStyle(fontSize: 13, color: Colors.grey[600]),
        ),
        const SizedBox(height: 18),
        _allianceInputs(
          'Red Alliance',
          MatchColors.red,
          _redCtrls,
          red,
          isRed: true,
        ),
        const SizedBox(height: 12),
        _allianceInputs(
          'Blue Alliance',
          MatchColors.blue,
          _blueCtrls,
          blue,
          isRed: false,
        ),
        const SizedBox(height: 16),
        _field(red, blue),
        if (showResult) ...[
          const SizedBox(height: 16),
        _resultCard(red, blue, redScore, blueScore, winProb),
        ],
      ],
    );
  }

  Widget _allianceInputs(
    String title,
    Color color,
    List<TextEditingController> ctrls,
    List<TeamStats> resolved, {
    required bool isRed,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.045),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: const Icon(Icons.groups_2_outlined, color: Colors.white, size: 16),
              ),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: List.generate(3, (i) {
              final number = ctrls[i].text.trim();
              final hasText = number.isNotEmpty;
              final isLoading = hasText && _loading.contains(number);
              final unavailable =
                  hasText && !isLoading && _unavailable.contains(number);
              final notFound =
                  hasText &&
                  !isLoading &&
                  !unavailable &&
                  _cache.containsKey(number) &&
                  _cache[number] == null;
              return Expanded(
                child: Padding(
                  padding: EdgeInsets.only(right: i < 2 ? 8 : 0),
                  child: TextField(
                    controller: ctrls[i],
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    onChanged: (_) => _onChanged(i, isRed),
                    decoration: InputDecoration(
                      hintText: 'Team',
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(vertical: 12),
                      suffixIcon: isLoading
                          ? const Padding(
                              padding: EdgeInsets.all(14),
                              child: SizedBox(
                                width: 12,
                                height: 12,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: MatchColors.yellor,
                                ),
                              ),
                            )
                          : unavailable
                          ? Icon(
                              Icons.error_outline,
                              size: 16,
                              color: Colors.red[400],
                            )
                          : notFound
                          ? Icon(
                              Icons.help_outline,
                              size: 16,
                              color: Colors.grey[400],
                            )
                          : null,
                    ),
                  ),
                ),
              );
            }),
          ),
          if (resolved.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: resolved
                  .map(
                    (t) => Chip(
                      label: Text(
                        '${t.teamNumber} · OPR ${t.opr?.toStringAsFixed(1) ?? '-'}',
                        style: const TextStyle(fontSize: 11),
                      ),
                      backgroundColor: color.withValues(alpha: 0.1),
                      side: BorderSide.none,
                    ),
                  )
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _field(List<TeamStats> red, List<TeamStats> blue) {
    Widget robot(TeamStats team, Color color, int index, bool isRed) {
      final phase = index * 1.7 + (isRed ? 0.0 : 0.9);
      final chip = Container(
        width: 42,
        height: 36,
        margin: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [color.withValues(alpha: .92), color.withValues(alpha: .68)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white.withValues(alpha: .95), width: 1.4),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: .32),
              blurRadius: 5,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Center(
          child: Text(
            team.teamNumber,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
      );

      return AnimatedBuilder(
        animation: _idleController,
        builder: (context, child) {
          final t = _idleController.value * 2 * math.pi;
          final dx = math.sin(t + phase) * 10;
          final dy = math.sin(2 * t + phase * 1.3) * 6;
          final angle = math.sin(t + phase * 1.6) * 0.20;
          return Transform.translate(
            offset: Offset(dx, dy),
            child: Transform.rotate(angle: angle, child: child),
          );
        },
        child: chip,
      );
    }

    Widget allianceZone({required bool isRed, required List<TeamStats> teams}) {
      final color = isRed ? MatchColors.red : MatchColors.blue;
      final label = isRed ? 'RED ALLIANCE' : 'BLUE ALLIANCE';
      return Expanded(
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: isRed ? Alignment.centerLeft : Alignment.centerRight,
              end: isRed ? Alignment.centerRight : Alignment.centerLeft,
              colors: [color.withValues(alpha: .30), color.withValues(alpha: .10)],
            ),
          ),
          child: Stack(
            children: [
              Positioned(
                left: isRed ? 0 : null,
                right: isRed ? null : 0,
                top: 0,
                bottom: 0,
                child: Container(
                  width: 8,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: isRed
                          ? [color.withValues(alpha: .9), color.withValues(alpha: .5)]
                          : [color.withValues(alpha: .5), color.withValues(alpha: .9)],
                    ),
                  ),
                ),
              ),
              Align(
                alignment: isRed ? Alignment.topLeft : Alignment.topRight,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 9, 12, 0),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        label,
                        style: TextStyle(
                          color: color,
                          fontSize: 9,
                          fontWeight: FontWeight.w900,
                          letterSpacing: .9,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              () {

                final slots = isRed
                    ? const [
                        Alignment(-0.55, -0.55),
                        Alignment(0.35, 0.60),
                        Alignment(0.60, -0.25),
                      ]
                    : const [
                        Alignment(0.55, -0.55),
                        Alignment(-0.35, 0.60),
                        Alignment(-0.60, -0.25),
                      ];
                return Stack(
                  children: [
                    for (final entry in teams.asMap().entries)
                      Align(
                        alignment: slots[entry.key % slots.length],
                        child: robot(entry.value, color, entry.key, isRed),
                      ),
                  ],
                );
              }(),
              if (teams.isEmpty)
                Center(
                  child: Text(
                    'Add teams',
                    style: TextStyle(
                      fontSize: 10,
                      color: color.withValues(alpha: .75),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    return Container(
      height: 220,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: const Color(0xff181d21),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xff0c0f11), width: 2),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: .28), blurRadius: 16, offset: const Offset(0, 6)),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(17),
        child: Stack(
          children: [
            Positioned.fill(
              child: Container(color: const Color(0xffe4ded0)),
            ),
            Positioned.fill(
              child: Row(
                children: [
                  allianceZone(isRed: true, teams: red),
                  Container(width: 2, color: Colors.white.withValues(alpha: .6)),
                  allianceZone(isRed: false, teams: blue),
                ],
              ),
            ),
            const Positioned(top: 6, left: 6, child: _CornerBracket(corner: _Corner.topLeft)),
            const Positioned(top: 6, right: 6, child: _CornerBracket(corner: _Corner.topRight)),
            const Positioned(bottom: 6, left: 6, child: _CornerBracket(corner: _Corner.bottomLeft)),
            const Positioned(bottom: 6, right: 6, child: _CornerBracket(corner: _Corner.bottomRight)),
          ],
        ),
      ),
    );
  }


  Widget _resultCard(
    List<TeamStats> red,
    List<TeamStats> blue,
    double redScore,
    double blueScore,
    double? winProb,
  ) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: MatchColors.yellor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'PREDICTED RESULT',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: Colors.white.withValues(alpha: 0.8),
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _scoreColumn('Red', redScore, red.isEmpty),
              const Text(
                'vs',
                style: TextStyle(color: Colors.white, fontSize: 14),
              ),
              _scoreColumn('Blue', blueScore, blue.isEmpty),
            ],
          ),
          if (winProb != null) ...[
            const SizedBox(height: 16),
            _probabilityBar(winProb),
            const SizedBox(height: 14),
            ..._scoutingNotes(red, blue, redScore, blueScore).map((note) => Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Text(note, style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: .95))),
            )),
          ],
        ],
      ),
    );
  }

  List<String> _scoutingNotes(List<TeamStats> red, List<TeamStats> blue, double redScore, double blueScore) {
    if (red.isEmpty || blue.isEmpty) return ['Add all six teams for a complete prediction.'];
    final favoredRed = redScore >= blueScore;
    final favored = favoredRed ? 'Red' : 'Blue';
    final underdog = favoredRed ? 'Blue' : 'Red';
    final leaders = favoredRed ? red : blue;
    final other = favoredRed ? blue : red;
    return [
      '$favored is predicted to win based on overall World Rating.',
      '$favored lead contributor: Team ${leaders.first.teamNumber}.',
      '$underdog lead contributor: Team ${other.first.teamNumber}.',
    ];
  }

  Widget _scoreColumn(String label, double score, bool empty) {
    return Column(
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: Colors.white.withValues(alpha: 0.85),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          empty ? '-' : score.round().toString(),
          style: const TextStyle(
            fontSize: 30,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        ),
      ],
    );
  }

  Widget _probabilityBar(double winProb) {
    final redPct = (winProb * 100).round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Red $redPct%',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
            Text(
              'Blue ${100 - redPct}%',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(
            value: winProb.clamp(0.0, 1.0),
            minHeight: 8,
            backgroundColor: Colors.white.withValues(alpha: 0.3),
            valueColor: const AlwaysStoppedAnimation(Colors.white),
          ),
        ),
      ],
    );
  }
}



enum _Corner { topLeft, topRight, bottomLeft, bottomRight }

class _CornerBracket extends StatelessWidget {
  const _CornerBracket({required this.corner});

  final _Corner corner;

  @override
  Widget build(BuildContext context) {
    final flipH = corner == _Corner.topRight || corner == _Corner.bottomRight;
    final flipV = corner == _Corner.bottomLeft || corner == _Corner.bottomRight;
    return Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()
        ..scale(flipH ? -1.0 : 1.0, flipV ? -1.0 : 1.0),
      child: CustomPaint(
        size: const Size(20, 20),
        painter: _BracketPainter(),
      ),
    );
  }
}

class _BracketPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: .8)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final path = Path()
      ..moveTo(0, size.height * .55)
      ..lineTo(0, 0)
      ..lineTo(size.width * .55, 0);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}