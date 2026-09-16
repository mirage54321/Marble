import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;

import 'constants.dart';
import 'retry_helper.dart';
import 'connectivity_check.dart';
import 'ai_scan.dart'
    show
        sanitizeLocalizedBox,
        boxContainmentFraction,
        parseSeverity,
        mergeOverlappingFindings,
        RetryCallback;

bool _isRetryableAiError(Object error) {
  final msg = error.toString();
  return msg.contains('experiencing high demand') ||
      msg.contains("Could not read the AI's response");
}

class AiRulesService {
  static const String _base = 'https://ridgeboticsapp.onrender.com';

  static const Map<String, String> _manualAssetPaths = {
    '2026': 'assets/rules/frc_2026_manual.pdf',
    '2025': 'assets/rules/frc_2025_manual.pdf',
    '2024': 'assets/rules/frc_2024_manual.pdf',
  };

  static Future<List<Finding>> analyzeImage(
    Uint8List imageBytes,
    String year, {
    int maxAttempts = 3,
    RetryCallback? onRetry,
  }) async {
    if (!ConnectivityCheck.isOnline) {
      throw Exception('offline');
    }

    final manualPath = _manualAssetPaths[year];
    if (manualPath == null) {
      throw Exception('No game manual available for $year');
    }

    final manualData = await rootBundle.load(manualPath);
    final base64Manual = base64Encode(manualData.buffer.asUint8List(
      manualData.offsetInBytes,
      manualData.lengthInBytes,
    ));

    final findings = await withBackoffRetry<List<Finding>>(
      () => _detectOnce(imageBytes, base64Manual, year),
      maxAttempts: maxAttempts,
      initialDelay: const Duration(seconds: 3),
      isRetryable: _isRetryableAiError,
      onRetry: onRetry,
    );

    return _dedupeFindings(findings);
  }

  static Future<List<Finding>> _detectOnce(
    Uint8List imageBytes,
    String base64Manual,
    String year,
  ) async {
    final base64Image = base64Encode(imageBytes);

    final body = {
      'contents': [
        {
          'parts': [
            {'text': _detectPromptText(year)},
            {
              'inline_data': {
                'mime_type': 'application/pdf',
                'data': base64Manual,
              }
            },
            {
              'inline_data': {
                'mime_type': 'image/jpeg',
                'data': base64Image,
              }
            },
          ]
        }
      ],
      'generationConfig': {
        'temperature': 0,
        'maxOutputTokens': 8192,
        'responseMimeType': 'application/json',
        'thinkingConfig': {'thinkingBudget': 3072},
      },
    };

    final response = await http
        .post(
          Uri.parse('$_base/analyzeImage'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 60));

    final data = jsonDecode(response.body) as Map<String, dynamic>;

    if (response.statusCode != 200) {
      final errMsg = data['error']?.toString() ?? 'Unknown error';
      if (_looksLikeQuotaError(errMsg)) {
        throw Exception('experiencing high demand');
      }
      throw Exception(errMsg);
    }

    final rawText = _extractText(data);
    if (rawText == null || rawText.isEmpty) {
      throw Exception('experiencing high demand');
    }

    try {
      final parsed = jsonDecode(rawText) as Map<String, dynamic>;

      BoundingBox? robotBox;
      final robotBox2d = parsed['robot_box_2d'] as List<dynamic>?;
      if (robotBox2d != null && robotBox2d.length == 4) {
        try {
          final candidate = BoundingBox.fromBox2D(robotBox2d);
          final isReasonablySized =
              candidate.width >= 0.05 && candidate.height >= 0.05;
          final isNotLazyFullFrameGuess =
              candidate.width <= 0.97 || candidate.height <= 0.97;
          if (isReasonablySized && isNotLazyFullFrameGuess) {
            robotBox = candidate;
          }
        } catch (_) {
          robotBox = null;
        }
      }

      final findingsJson = parsed['findings'] as List<dynamic>? ?? [];
      return findingsJson.map((f) {
        final map = f as Map<String, dynamic>;
        final box2d = map['box_2d'] as List<dynamic>?;
        BoundingBox? box;
        if (box2d != null && box2d.length == 4) {
          try {
            box = sanitizeLocalizedBox(BoundingBox.fromBox2D(box2d));
          } catch (_) {
            box = null;
          }
        }
        if (robotBox == null) {
          box = null;
        } else if (box != null &&
            boxContainmentFraction(box, robotBox) < 0.5) {
          box = null;
        }
        return Finding(
          title: map['title'] as String? ?? 'Issue found',
          description: map['description'] as String? ?? '',
          severity: parseSeverity(map['severity']),
          box: box,
          isReported: false,
        );
      }).toList();
    } catch (e) {
      throw Exception("Could not read the AI's response, please try again.");
    }
  }

  static String _detectPromptText(String year) =>
      'You are helping a FRC (FIRST Robotics Competition) team do a quick '
      'pre-inspection check against the attached $year FRC game manual. '
      'Use ONLY that manual as the source of truth because rules change '
      'each season. Your job is to point out things worth double checking '
      'against the rulebook, not to give a final ruling on legality. Do '
      'not say a robot is compliant, and do not say a robot is in '
      'violation, only that something looks worth a closer look. The '
      'photo may have a lot of plain background around the robot, so look '
      'carefully at where the robot itself actually is, and make sure '
      'every bounding box you give actually sits on the robot, not on the '
      'background around it.\n\n'
      'Only check things that can actually be judged from a static photo: '
      'bumper presence, bumper color and numbering, bumper height and '
      'coverage as visible, and whether the visible outline of the robot '
      'appears to exceed the frame perimeter. Do not attempt to judge '
      'wiring correctness, breaker sizing, component legality, or any '
      'rule that depends on internal specifications, mechanism range of '
      'motion, or parts that are partially hidden. If a rule cannot be '
      'judged from what is visible in this single photo, do not comment '
      'on it.\n\n'
      'Be careful with severity. Many of these rules involve exact '
      'measurements (bumper height in inches, total robot height, exact '
      'frame perimeter) that cannot be confirmed from a photo alone, only '
      'estimated by eye. Use "critical" ONLY when a violation is '
      'obvious and unambiguous just from looking, with no real doubt: '
      'bumpers clearly and entirely missing, a bumper\'s numbering '
      'clearly absent, or the robot obviously and grossly over a limit '
      'by a wide margin. For anything that merely looks like it MIGHT be '
      'out of range, or where confirming it would require an actual '
      'measurement, use "warning" and phrase the description as '
      'something to double check or measure, not as a confirmed '
      'violation. Do not assume a measurement-dependent rule is being '
      'violated just because it cannot be verified from the photo; the '
      'default when uncertain is "warning", not "critical". Use "ok" '
      'when what is visible clearly satisfies the rule.\n\n'
      'First, give a bounding box for the robot itself: the tightest box '
      'that contains the whole visible robot, in the same "box_2d" format '
      'described below.\n\n'
      'Cite the specific rule number when the manual supports it. For each '
      'thing you flag, give a TIGHT bounding box around exactly that item '
      'only (not the whole robot, not a wide region around it) using '
      'Gemini\'s standard "box_2d" format: [ymin, xmin, ymax, xmax], each '
      '0-1000, relative to the full photo. Before answering, double check '
      'that the box you give actually contains the item you described, '
      'falls inside the robot\'s own bounding box, and is not centered on '
      'empty background or a different part of the robot. If you cannot '
      'pin down a confident, accurate box for something, leave its '
      '"box_2d" out entirely rather than guessing one. Give each finding '
      'a short, specific title.\n\n'
      'Return an empty findings list ONLY if the image is clear enough to '
      'check the items above and nothing looks worth a closer look. If '
      'the image is too dark, blurry, obstructed, or too distant to check '
      'bumpers or frame perimeter, return one item titled "Photo quality '
      'prevents rule check" with box_2d [400,400,600,600] rather than an '
      'empty list. Respond only with JSON in this exact format:\n\n'
      '{"robot_box_2d":[0,0,0,0],"findings":[{"title":"short specific '
      'issue name","description":"one or two sentence explanation of '
      'what to double check, cite rule number if applicable","severity":'
      '"critical|warning|ok","box_2d":[0,0,0,0]}]}\n\n'
      'If nothing looks worth checking, return {"robot_box_2d":[0,0,0,0],'
      '"findings":[]}.';

  static bool _looksLikeQuotaError(String msg) {
    final lower = msg.toLowerCase();
    return lower.contains('quota') ||
        lower.contains('429') ||
        lower.contains('rate limit') ||
        lower.contains('resource_exhausted');
  }

  static String? _extractText(Map<String, dynamic> data) {
    try {
      final candidates = data['candidates'] as List<dynamic>?;
      final text = candidates?[0]['content']['parts'][0]['text'] as String?;
      return text?.replaceAll('```json', '').replaceAll('```', '').trim();
    } catch (e) {
      return null;
    }
  }

  static List<Finding> _dedupeFindings(List<Finding> findings) {
    final seenTitles = <String>{};
    final byTitle = <Finding>[];
    for (final f in findings) {
      final key = f.title.trim().toLowerCase();
      if (seenTitles.add(key)) byTitle.add(f);
    }
    return mergeOverlappingFindings(byTitle);
  }
}