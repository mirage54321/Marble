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
        const SizedBox(height: 16),
        Text(
          'Each match is predicted the way the simulator does it: add up every team\u2019s World Rating on each alliance and pick the higher total. '
          'Only ratings from events that finished before that match\u2019s event started are used, so the model never sees the result it is being graded on. '
          'Ties and matches where no team had a rating yet are skipped.',
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