import 'package:flutter/material.dart';
import '../../tap_cursor.dart';

import '../match_models.dart';
import '../match_scope.dart';
import '../match_theme.dart';

/// Only shown in the bottom nav when signed in as the test team (see
/// MatchDataController.canSeeAccuracy).
class MatchAccuracyTab extends StatefulWidget {
  const MatchAccuracyTab({super.key});

  @override
  State<MatchAccuracyTab> createState() => _MatchAccuracyTabState();
}

class _MatchAccuracyTabState extends State<MatchAccuracyTab> {
  Future<ModelAccuracy>? _future;

  @override
  Widget build(BuildContext context) {
    final controller = MatchScope.of(context);
    _future ??= controller.loadModelAccuracy();

    return FutureBuilder<ModelAccuracy>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(color: MatchColors.yellor),
                const SizedBox(height: 14),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Text(
                    'Checking predictions against every match\u2026 this can take a moment if the server was asleep.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                  ),
                ),
              ],
            ),
          );
        }

        if (snapshot.hasError) {
          final message = snapshot.error is StateError
              ? (snapshot.error as StateError).message
              : 'Could not reach the accuracy service.';
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey[600]),
                  ),
                  const SizedBox(height: 12),
                  TapCursor(
                    onTap: _reload,
                    child: const Text(
                      'Try again',
                      style: TextStyle(
                        color: MatchColors.yellorDark,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        return RefreshIndicator(
          color: MatchColors.yellor,
          onRefresh: () async {
            final f = MatchScope.of(context).loadModelAccuracy();
            setState(() => _future = f);
            try {
              await f;
            } catch (_) {}
          },
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: _content(snapshot.data!),
          ),
        );
      },
    );
  }

  void _reload() {
    setState(() => _future = MatchScope.of(context).loadModelAccuracy());
  }

  List<Widget> _content(ModelAccuracy a) {
    final hasData = a.games > 0 && a.accuracyPct != null;
    return [
      const Text(
        'Model Accuracy',
        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 4),
      Text(
        'How well the matchup simulator has predicted real matches this season',
        style: TextStyle(fontSize: 13, color: Colors.grey[600]),
      ),
      const SizedBox(height: 16),
      if (!hasData)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Text(
            'No finished matches could be checked yet.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey[600]),
          ),
        )
      else ...[
        _bigCard(
          label: 'PREDICTED THE WINNER',
          value: '${a.accuracyPct!.toStringAsFixed(1)}%',
          caption: '${a.correct} of ${a.games} matches called correctly',
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _smallCard(
                label: 'Off by (avg)',
                value: '${a.avgMarginError?.toStringAsFixed(1) ?? '-'} pts',
                caption: 'predicted vs real point margin',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _smallCard(
                label: 'Games checked',
                value: '${a.games}',
                caption: 'across ${a.eventsCounted} events',
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _smallCard(
                label: 'Log loss',
                value: a.logLoss?.toStringAsFixed(3) ?? '-',
                caption: 'lower is better, 0.693 is a coin flip',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _smallCard(
                label: 'Brier score',
                value: a.brier?.toStringAsFixed(3) ?? '-',
                caption: 'lower is better, 0.25 is a coin flip',
              ),
            ),
          ],
        ),
        ..._breakdown(a.breakdown),
        const SizedBox(height: 16),
        Text(
          a.gradedOn == 'holdout'
              ? 'Scores above come from events the settings were not tuned on, so they are an honest estimate.'
                  '${a.tunedAccuracyPct != null ? ' On the events used for tuning the model scores ${a.tunedAccuracyPct!.toStringAsFixed(1)}%.' : ''}'
              : 'Not enough events yet to hold some back, so these scores include the events used for tuning.',
          style: TextStyle(fontSize: 11, height: 1.5, color: Colors.grey[500]),
        ),
        const SizedBox(height: 8),
        Text(
          'Each match is predicted the way the app does it: add up every team\u2019s rating on each alliance and pick the higher total. '
          'A team starts each event with its rating from earlier events (recent ones count more, last season fills in for new teams), then its rating updates after every match, ignoring foul points. '
          'A match is always predicted before its result is learned, so the model never sees the answer it is graded on. '
          'Ties are skipped.',
          style: TextStyle(fontSize: 11, height: 1.5, color: Colors.grey[500]),
        ),
        if (a.refreshedAt != null) ...[
          const SizedBox(height: 8),
          Text(
            'Updated ${_ago(a.refreshedAt!)}',
            style: TextStyle(fontSize: 11, color: Colors.grey[400]),
          ),
        ],
      ],
    ];
  }

  List<Widget> _breakdown(List<AccuracyBreakdownRow> rows) {
    if (rows.isEmpty) return [];
    final groups = <String, List<AccuracyBreakdownRow>>{};
    for (final r in rows) {
      groups.putIfAbsent(r.group, () => []).add(r);
    }
    return [
      const SizedBox(height: 20),
      const Text(
        'Where it is right and wrong',
        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 8),
      for (final entry in groups.entries) _breakdownCard(entry.key, entry.value),
    ];
  }

  Widget _breakdownCard(String title, List<AccuracyBreakdownRow> rows) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.black.withValues(alpha: 0.07)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Colors.grey[600],
            ),
          ),
          const SizedBox(height: 8),
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(r.label, style: const TextStyle(fontSize: 13)),
                  ),
                  Text(
                    '${r.games} matches',
                    style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 48,
                    child: Text(
                      '${r.accuracyPct.toStringAsFixed(1)}%',
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: MatchColors.yellorDark,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _bigCard({
    required String label,
    required String value,
    required String caption,
  }) {
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
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: Colors.white.withValues(alpha: 0.8),
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(
              fontSize: 40,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            caption,
            style: TextStyle(
              fontSize: 12,
              color: Colors.white.withValues(alpha: 0.85),
            ),
          ),
        ],
      ),
    );
  }

  Widget _smallCard({
    required String label,
    required String value,
    required String caption,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.black.withValues(alpha: 0.07)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Colors.grey[600],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: MatchColors.yellorDark,
            ),
          ),
          const SizedBox(height: 4),
          Text(caption, style: TextStyle(fontSize: 11, color: Colors.grey[500])),
        ],
      ),
    );
  }

  String _ago(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours} hr ago';
    return '${diff.inDays} day${diff.inDays == 1 ? '' : 's'} ago';
  }
}