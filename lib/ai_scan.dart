import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'constants.dart';
import 'retry_helper.dart';
import 'connectivity_check.dart';

typedef RetryCallback = void Function(
    int attempt, int maxAttempts, Duration nextDelay);

const double _minPlausibleBoxFraction = 0.02;
const double _maxPlausibleBoxFraction = 0.75;
const double _maxPlausibleAspectRatio = 6.0;

BoundingBox? sanitizeLocalizedBox(BoundingBox? box) {
  if (box == null) return null;

  if (box.width < _minPlausibleBoxFraction ||
      box.height < _minPlausibleBoxFraction) {
    return null;
  }
  if (box.width > _maxPlausibleBoxFraction ||
      box.height > _maxPlausibleBoxFraction) {
    return null;
  }

  final aspectRatio = box.width > box.height
      ? box.width / box.height
      : box.height / box.width;
  if (aspectRatio > _maxPlausibleAspectRatio) {
    return null;
  }

  const tolerance = 0.02;
  if (box.x < -tolerance ||
      box.y < -tolerance ||
      box.x + box.width > 1.0 + tolerance ||
      box.y + box.height > 1.0 + tolerance) {
    return null;
  }

  return box;
}

bool _isRetryableAiError(Object error) {
  final msg = error.toString();
  return msg.contains('experiencing high demand') ||
      msg.contains("Could not read the AI's response");
}

class AiService {
  static const String _base = 'https://ridgeboticsapp.onrender.com';

  static Future<void> reportFinding({
    required String scanId,
    required String findingId,
    required Finding finding,
    required String errorType,
    required String scanMode,
    String userComment = '',
  }) async {
    final response = await http
        .post(
          Uri.parse('$_base/reportFinding'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'scanId': scanId,
            'findingId': findingId,
            'scanMode': scanMode,
            'errorType': errorType,
            'title': finding.title,
            'description': finding.description,
            'severity': finding.severity.name,
            'userComment': userComment,
          }),
        )
        .timeout(const Duration(seconds: 20));

    if (response.statusCode >= 200 && response.statusCode < 300) return;

    try {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      throw Exception(data['error']?.toString() ?? 'Could not submit report');
    } catch (error) {
      if (error is Exception) rethrow;
      throw Exception('Could not submit report');
    }
  }

  static Future<List<Finding>> analyzeImage(
    Uint8List imageBytes, {
    int maxAttempts = 3,
    RetryCallback? onRetry,
  }) async {
    if (!ConnectivityCheck.isOnline) {
      throw Exception('offline');
    }

    final findings = await withBackoffRetry<List<Finding>>(
      () => _detectOnce(imageBytes),
      maxAttempts: maxAttempts,
      initialDelay: const Duration(seconds: 3),
      isRetryable: _isRetryableAiError,
      onRetry: onRetry,
    );

    return _dedupeFindings(findings);
  }

  static Future<List<Finding>> _detectOnce(Uint8List imageBytes) async {
    final base64Image = base64Encode(imageBytes);

    final body = {
      'contents': [
        {
          'parts': [
            {'text': _detectPromptText},
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

  static const String _detectPromptText =
      'You are helping a FRC (FIRST Robotics Competition) team do a quick '
      'visual check of their robot before a real inspection. Your job is to '
      'point out things worth a closer look, not to give a final verdict on '
      'safety or compliance. The photo may have a lot of plain background '
      'around the robot, so look carefully at where the robot itself '
      'actually is, and make sure every bounding box you give actually '
      'sits on the robot, not on the background around it.\n\n'
      'Look for things like exposed conductors or damaged insulation, '
      'loose or unsecured wiring, loose connectors, unprotected battery '
      'terminals, loose or missing fasteners, cracked or bent frame '
      'members, corrosion, loose or misaligned belts or chains, sharp '
      'edges, and parts that look like they could fail in a match. Do not '
      'invent defects: ordinary screws, mounting holes, zip ties, and '
      'normal wires are not problems by themselves.\n\n'
      'Never identify what a button, light, or switch does. Do not label '
      'anything as an emergency stop, e-stop, safety light, or any other '
      'safety-critical control, even if it looks like one. If you notice a '
      'button, light, or switch that looks worth checking, describe only '
      'what you see physically (for example, "unlabeled red button near the '
      'battery") and let the team confirm its actual function themselves.\n\n'
      'Only flag something if you can actually see it clearly enough to '
      'describe specifically. If you are not confident something is an '
      'issue, phrase it as something to double check rather than a '
      'confirmed problem.\n\n'
      'For each thing you flag, give a TIGHT bounding box around exactly '
      'that item only (not the whole robot, not a wide region around it) '
      'using Gemini\'s standard "box_2d" format: [ymin, xmin, ymax, xmax], '
      'each 0-1000, relative to the full photo. Before answering, double '
      'check that the box you give actually contains the item you '
      'described and is not centered on empty background or a different '
      'part of the robot. Give each finding a short, specific title.\n\n'
      'Return an empty findings list ONLY when the photo is clear enough '
      'to inspect and you see nothing worth a closer look. If the image is '
      'too dark, blurry, obstructed, or too distant for a meaningful '
      'check, return one item titled "Photo quality prevents inspection" '
      'with box_2d [400,400,600,600] instead of returning an empty list. '
      'Respond only with JSON in this exact format:\n\n'
      '{"findings":[{"title":"short specific issue name","description":'
      '"one or two sentence explanation of what to look at and why",'
      '"severity":"critical|warning|ok","box_2d":[0,0,0,0]}]}\n\n'
      'If nothing stands out, return {"findings":[]}.';

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
}

ScanStatus parseSeverity(dynamic value) {
  final s = (value as String? ?? '').toLowerCase();
  if (s.contains('critical') || s == 'high') return ScanStatus.critical;
  if (s.contains('warn') || s == 'medium') return ScanStatus.warning;
  return ScanStatus.ok;
}

int severityRank(ScanStatus s) {
  switch (s) {
    case ScanStatus.critical:
      return 2;
    case ScanStatus.warning:
      return 1;
    case ScanStatus.ok:
      return 0;
  }
}

double boxOverlapRatio(BoundingBox? a, BoundingBox? b) {
  if (a == null || b == null) return 0.0;

  final interLeft = a.x > b.x ? a.x : b.x;
  final interTop = a.y > b.y ? a.y : b.y;
  final interRight =
      (a.x + a.width) < (b.x + b.width) ? (a.x + a.width) : (b.x + b.width);
  final interBottom = (a.y + a.height) < (b.y + b.height)
      ? (a.y + a.height)
      : (b.y + b.height);

  final interWidth = interRight - interLeft;
  final interHeight = interBottom - interTop;
  if (interWidth <= 0 || interHeight <= 0) return 0.0;

  final interArea = interWidth * interHeight;
  final aArea = a.width * a.height;
  final bArea = b.width * b.height;
  final unionArea = aArea + bArea - interArea;
  if (unionArea <= 0) return 0.0;

  return interArea / unionArea;
}

List<Finding> mergeOverlappingFindings(
  List<Finding> findings, {
  double overlapThreshold = 0.3,
}) {
  final used = List<bool>.filled(findings.length, false);
  final merged = <Finding>[];

  for (var i = 0; i < findings.length; i++) {
    if (used[i]) continue;
    used[i] = true;
    var best = findings[i];

    for (var j = i + 1; j < findings.length; j++) {
      if (used[j]) continue;
      if (boxOverlapRatio(best.box, findings[j].box) >= overlapThreshold) {
        used[j] = true;
        if (severityRank(findings[j].severity) > severityRank(best.severity)) {
          best = findings[j];
        }
      }
    }

    merged.add(best);
  }

  return merged;
}

List<Finding> _dedupeFindings(List<Finding> findings) {
  final seenTitles = <String>{};
  final byTitle = <Finding>[];
  for (final f in findings) {
    final key = f.title.trim().toLowerCase();
    if (seenTitles.add(key)) byTitle.add(f);
  }
  return mergeOverlappingFindings(byTitle);
}