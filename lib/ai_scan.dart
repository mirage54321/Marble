import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

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

double boxContainmentFraction(BoundingBox inner, BoundingBox outer) {
  final interLeft = inner.x > outer.x ? inner.x : outer.x;
  final interTop = inner.y > outer.y ? inner.y : outer.y;
  final interRight = (inner.x + inner.width) < (outer.x + outer.width)
      ? (inner.x + inner.width)
      : (outer.x + outer.width);
  final interBottom = (inner.y + inner.height) < (outer.y + outer.height)
      ? (inner.y + inner.height)
      : (outer.y + outer.height);

  final interWidth = interRight - interLeft;
  final interHeight = interBottom - interTop;
  if (interWidth <= 0 || interHeight <= 0) return 0.0;

  final innerArea = inner.width * inner.height;
  if (innerArea <= 0) return 0.0;

  return (interWidth * interHeight) / innerArea;
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
        'maxOutputTokens': 16384,
        'responseMimeType': 'application/json',
        'thinkingConfig': {'thinkingBudget': 4096},
      },
    };

    final response = await http
        .post(
          Uri.parse('$_base/analyzeImage'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 110));

    final data = jsonDecode(response.body) as Map<String, dynamic>;

    if (response.statusCode != 200) {
      final errMsg = data['error']?.toString() ?? 'Unknown error';
      debugPrint('[scan] non-200 (${response.statusCode}): $errMsg');
      if (errMsg.contains('all_quota_exhausted_for_today')) {
        throw Exception('all AI capacity is used up for today, please try again after midnight Pacific time or do a manual inspection for now');
      }
      if (_looksLikeQuotaError(errMsg)) {
        throw Exception('experiencing high demand');
      }
      throw Exception(errMsg);
    }

    final rawText = _extractText(data);
    if (rawText == null || rawText.isEmpty) {
      throw Exception("Could not read the AI's response, please try again.");
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
      'First, give a bounding box for the robot itself: the tightest box '
      'that contains the whole visible robot, in the same "box_2d" format '
      'described below.\n\n'
      'For each thing you flag, give a TIGHT bounding box around exactly '
      'that item only (not the whole robot, not a wide region around it) '
      'using Gemini\'s standard "box_2d" format: [ymin, xmin, ymax, xmax], '
      'each 0-1000, relative to the full photo. Zoom in mentally on the '
      'item before setting coordinates: trace its actual visible edges '
      'closely rather than a loose approximate box, and do not pad the '
      'box with surrounding material or empty space on any side. Before '
      'answering, double check that the box you give actually contains '
      'the item you described, tightly hugs its real edges, falls inside '
      'the robot\'s own bounding box, and is not centered on empty '
      'background or a different part of the robot. If '
      'you cannot pin down a confident, accurate box for something, leave '
      'its "box_2d" out entirely rather than guessing one. Give each '
      'finding a short, specific title.\n\n'
      'Give at least 3 findings unless the robot genuinely has nothing '
      'worth checking anywhere. Look across multiple distinct areas of '
      'the robot (wiring, fasteners, frame, belts/chains, battery '
      'mounting, etc.) rather than stopping after the first couple of '
      'things you notice. If an area you checked looks fine, include it '
      'as its own finding with severity "ok" and a short note on what you '
      'checked and confirmed looked fine there, naming the specific part '
      '(not a generic filler item). Never invent a defect just to reach '
      '3; use "ok" findings for genuinely fine areas instead. Only return '
      'fewer than 3 findings if the robot has so little visible in the '
      'photo that there truly is not more than that to comment on.\n\n'
      'Return an empty findings list ONLY when the photo is clear enough '
      'to inspect and you see nothing worth a closer look. If the image is '
      'too dark, blurry, obstructed, or too distant for a meaningful '
      'check, return one item titled "Photo quality prevents inspection" '
      'with box_2d [400,400,600,600] instead of returning an empty list. '
      'Respond only with JSON in this exact format:\n\n'
      '{"robot_box_2d":[0,0,0,0],"findings":[{"title":"short specific '
      'issue name","description":"one or two sentence explanation of '
      'what to look at and why","severity":"critical|warning|ok",'
      '"box_2d":[0,0,0,0]}]}\n\n'
      'If nothing stands out, return {"robot_box_2d":[0,0,0,0],'
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

const String _refineBase = 'https://ridgeboticsapp.onrender.com';

class _JpegCrop {
  final String base64Jpeg;
  final int width;
  final int height;

  const _JpegCrop({
    required this.base64Jpeg,
    required this.width,
    required this.height,
  });
}

_JpegCrop _cropToJpeg(
  Uint8List originalBytes,
  double regionX,
  double regionY,
  double regionWidth,
  double regionHeight,
) {
  final decoded = img.decodeImage(originalBytes);
  if (decoded == null) {
    return _JpegCrop(base64Jpeg: base64Encode(originalBytes), width: 0, height: 0);
  }

  final cropX = (regionX * decoded.width).round().clamp(0, decoded.width - 1);
  final cropY =
      (regionY * decoded.height).round().clamp(0, decoded.height - 1);
  final cropWidth =
      (regionWidth * decoded.width).round().clamp(1, decoded.width - cropX);
  final cropHeight =
      (regionHeight * decoded.height).round().clamp(1, decoded.height - cropY);

  final cropped = img.copyCrop(
    decoded,
    x: cropX,
    y: cropY,
    width: cropWidth,
    height: cropHeight,
  );

  return _JpegCrop(
    base64Jpeg: base64Encode(img.encodeJpg(cropped, quality: 90)),
    width: cropWidth,
    height: cropHeight,
  );
}

Future<BoundingBox?> refineFindingBox(
  Uint8List imageBytes,
  Finding finding, {
  int maxAttempts = 2,
}) async {
  final roughBox = finding.box;
  if (roughBox == null) return null;
  if (!ConnectivityCheck.isOnline) return null;

  const padding = 0.15;
  final regionLeft = (roughBox.x - padding).clamp(0.0, 1.0);
  final regionTop = (roughBox.y - padding).clamp(0.0, 1.0);
  final regionRight =
      (roughBox.x + roughBox.width + padding).clamp(0.0, 1.0);
  final regionBottom =
      (roughBox.y + roughBox.height + padding).clamp(0.0, 1.0);
  final regionX = regionLeft;
  final regionY = regionTop;
  final regionWidth = (regionRight - regionLeft).clamp(0.1, 1.0);
  final regionHeight = (regionBottom - regionTop).clamp(0.1, 1.0);

  final crop = _cropToJpeg(
    imageBytes,
    regionX,
    regionY,
    regionWidth,
    regionHeight,
  );

  try {
    return await withBackoffRetry<BoundingBox?>(
      () => _refineOnce(
        crop.base64Jpeg,
        crop.width,
        crop.height,
        finding.title,
        finding.description,
        regionX,
        regionY,
        regionWidth,
        regionHeight,
      ),
      maxAttempts: maxAttempts,
      initialDelay: const Duration(seconds: 2),
      isRetryable: _isRetryableAiError,
    );
  } catch (_) {
    return null;
  }
}

BoundingBox? _tightBoxFromMask(
  String maskData,
  int boxPixelWidth,
  int boxPixelHeight,
) {
  try {
    var b64 = maskData;
    final commaIdx = b64.indexOf(',');
    if (b64.startsWith('data:') && commaIdx != -1) {
      b64 = b64.substring(commaIdx + 1);
    }

    final decoded = img.decodeImage(base64Decode(b64));
    if (decoded == null) return null;

    final resized = img.copyResize(
      decoded,
      width: boxPixelWidth.clamp(1, 4096),
      height: boxPixelHeight.clamp(1, 4096),
    );

    var minX = resized.width;
    var minY = resized.height;
    var maxX = -1;
    var maxY = -1;

    for (var y = 0; y < resized.height; y++) {
      for (var x = 0; x < resized.width; x++) {
        final pixel = resized.getPixel(x, y);
        final luminance = (pixel.r + pixel.g + pixel.b) / 3.0;
        if (luminance > 127) {
          if (x < minX) minX = x;
          if (y < minY) minY = y;
          if (x > maxX) maxX = x;
          if (y > maxY) maxY = y;
        }
      }
    }

    if (maxX < minX || maxY < minY) return null;

    return BoundingBox(
      x: minX / resized.width,
      y: minY / resized.height,
      width: (maxX - minX + 1) / resized.width,
      height: (maxY - minY + 1) / resized.height,
    );
  } catch (_) {
    return null;
  }
}

Future<BoundingBox?> _refineOnce(
  String base64Crop,
  int cropPixelWidth,
  int cropPixelHeight,
  String title,
  String description,
  double regionX,
  double regionY,
  double regionWidth,
  double regionHeight,
) async {
  final body = {
    'contents': [
      {
        'parts': [
          {
            'text': 'You are looking at a zoomed-in crop from a larger '
                'robot photo. Somewhere in this crop is the following '
                'specific item:\n\nTitle: $title\nDescription: '
                '$description\n\n'
                'Find exactly that item and give both its bounding box '
                'and its segmentation mask. If you genuinely cannot find '
                'this exact item anywhere in this crop, respond with '
                '{"items":[]}. Output a JSON object with an "items" list '
                'where each entry contains the 2D bounding box in the '
                'key "box_2d" as [ymin, xmin, ymax, xmax], each 0-1000 '
                'relative to this crop, and the segmentation mask in the '
                'key "mask" as a base64 encoded PNG probability map '
                'covering just that bounding box. Respond only with JSON '
                'in this exact format: {"items":[{"box_2d":[0,0,0,0],'
                '"mask":"..."}]}',
          },
          {
            'inline_data': {
              'mime_type': 'image/jpeg',
              'data': base64Crop,
            }
          },
        ]
      }
    ],
    'generationConfig': {
      'temperature': 0,
      'maxOutputTokens': 2048,
      'responseMimeType': 'application/json',
      'thinkingConfig': {'thinkingBudget': 0},
    },
  };

  final response = await http
      .post(
        Uri.parse('$_refineBase/analyzeImage'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      )
      .timeout(const Duration(seconds: 30));

  final data = jsonDecode(response.body) as Map<String, dynamic>;

  if (response.statusCode != 200) {
    final errMsg = data['error']?.toString() ?? 'Unknown error';
    if (AiService._looksLikeQuotaError(errMsg)) {
      throw Exception('experiencing high demand');
    }
    throw Exception(errMsg);
  }

  final rawText = AiService._extractText(data);
  if (rawText == null || rawText.isEmpty) {
    throw Exception('experiencing high demand');
  }

  try {
    final parsed = jsonDecode(rawText) as Map<String, dynamic>;
    final items = parsed['items'] as List<dynamic>?;
    if (items == null || items.isEmpty) return null;

    final item = items.first as Map<String, dynamic>;
    final box2d = item['box_2d'] as List<dynamic>?;
    if (box2d == null || box2d.length != 4) return null;

    final cropBox = BoundingBox.fromBox2D(box2d);

    var effectiveCropBox = cropBox;
    final maskData = item['mask'] as String?;
    if (maskData != null) {
      final boxPixelWidth = (cropBox.width * cropPixelWidth).round();
      final boxPixelHeight = (cropBox.height * cropPixelHeight).round();
      if (boxPixelWidth > 0 && boxPixelHeight > 0) {
        final tight =
            _tightBoxFromMask(maskData, boxPixelWidth, boxPixelHeight);
        if (tight != null) {
          effectiveCropBox = BoundingBox(
            x: cropBox.x + tight.x * cropBox.width,
            y: cropBox.y + tight.y * cropBox.height,
            width: tight.width * cropBox.width,
            height: tight.height * cropBox.height,
          );
        }
      }
    }

    final fullBox = BoundingBox(
      x: regionX + effectiveCropBox.x * regionWidth,
      y: regionY + effectiveCropBox.y * regionHeight,
      width: effectiveCropBox.width * regionWidth,
      height: effectiveCropBox.height * regionHeight,
    );
    return sanitizeLocalizedBox(fullBox);
  } catch (e) {
    throw Exception("Could not read the AI's response, please try again.");
  }
}

bool? _replicateConfiguredCache;

Future<bool> _isReplicateConfigured() async {
  if (_replicateConfiguredCache != null) return _replicateConfiguredCache!;
  try {
    final response = await http
        .get(Uri.parse('$_refineBase/health'))
        .timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) {
      _replicateConfiguredCache = false;
      return false;
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final configured = data['replicateConfigured'] == true;
    _replicateConfiguredCache = configured;
    return configured;
  } catch (_) {
    _replicateConfiguredCache = false;
    return false;
  }
}

Future<BoundingBox?> segmentFindingMask(
  Uint8List imageBytes,
  Finding finding,
) async {
  if (!await _isReplicateConfigured()) return null;

  final box = finding.box;
  if (box == null) return null;
  if (!ConnectivityCheck.isOnline) return null;

  const padding = 0.08;
  final regionLeft = (box.x - padding).clamp(0.0, 1.0);
  final regionTop = (box.y - padding).clamp(0.0, 1.0);
  final regionRight = (box.x + box.width + padding).clamp(0.0, 1.0);
  final regionBottom = (box.y + box.height + padding).clamp(0.0, 1.0);
  final regionX = regionLeft;
  final regionY = regionTop;
  final regionWidth = (regionRight - regionLeft).clamp(0.05, 1.0);
  final regionHeight = (regionBottom - regionTop).clamp(0.05, 1.0);

  final crop =
      _cropToJpeg(imageBytes, regionX, regionY, regionWidth, regionHeight);
  if (crop.width <= 0 || crop.height <= 0) return null;

  final boxLeftInCrop = ((box.x - regionX) / regionWidth).clamp(0.0, 1.0);
  final boxTopInCrop = ((box.y - regionY) / regionHeight).clamp(0.0, 1.0);
  final boxWidthInCrop = (box.width / regionWidth).clamp(0.0, 1.0);
  final boxHeightInCrop = (box.height / regionHeight).clamp(0.0, 1.0);

  final pixelBox = [
    (boxLeftInCrop * crop.width).round(),
    (boxTopInCrop * crop.height).round(),
    (boxWidthInCrop * crop.width).round().clamp(1, crop.width),
    (boxHeightInCrop * crop.height).round().clamp(1, crop.height),
  ];

  try {
    final response = await http
        .post(
          Uri.parse('$_refineBase/segmentFinding'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'image': crop.base64Jpeg, 'box': pixelBox}),
        )
        .timeout(const Duration(seconds: 45));

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode != 200) return null;

    final maskUrl = data['maskUrl'] as String?;
    if (maskUrl == null) return null;

    final maskResponse =
        await http.get(Uri.parse(maskUrl)).timeout(const Duration(seconds: 30));
    if (maskResponse.statusCode != 200) return null;

    final maskImage = img.decodeImage(maskResponse.bodyBytes);
    if (maskImage == null) return null;

    var minX = maskImage.width;
    var minY = maskImage.height;
    var maxX = -1;
    var maxY = -1;

    for (var y = 0; y < maskImage.height; y++) {
      for (var x = 0; x < maskImage.width; x++) {
        final pixel = maskImage.getPixel(x, y);
        final luminance = (pixel.r + pixel.g + pixel.b) / 3;
        if (luminance > 127) {
          if (x < minX) minX = x;
          if (y < minY) minY = y;
          if (x > maxX) maxX = x;
          if (y > maxY) maxY = y;
        }
      }
    }

    if (maxX < minX || maxY < minY) return null;

    final maskBoxInCrop = BoundingBox(
      x: minX / maskImage.width,
      y: minY / maskImage.height,
      width: (maxX - minX + 1) / maskImage.width,
      height: (maxY - minY + 1) / maskImage.height,
    );

    final fullBox = BoundingBox(
      x: regionX + maskBoxInCrop.x * regionWidth,
      y: regionY + maskBoxInCrop.y * regionHeight,
      width: maskBoxInCrop.width * regionWidth,
      height: maskBoxInCrop.height * regionHeight,
    );

    return sanitizeLocalizedBox(fullBox);
  } catch (_) {
    return null;
  }
}

BoundingBox snapBoxToEdges(Uint8List imageBytes, BoundingBox box) {
  final decoded = img.decodeImage(imageBytes);
  if (decoded == null) return box;

  const margin = 0.15;
  final regionX = (box.x - box.width * margin).clamp(0.0, 1.0);
  final regionY = (box.y - box.height * margin).clamp(0.0, 1.0);
  final regionRight = (box.x + box.width * (1 + margin)).clamp(0.0, 1.0);
  final regionBottom = (box.y + box.height * (1 + margin)).clamp(0.0, 1.0);
  final regionWidth = (regionRight - regionX).clamp(0.01, 1.0);
  final regionHeight = (regionBottom - regionY).clamp(0.01, 1.0);

  final cropX = (regionX * decoded.width).round().clamp(0, decoded.width - 1);
  final cropY =
      (regionY * decoded.height).round().clamp(0, decoded.height - 1);
  final rawCropWidth =
      (regionWidth * decoded.width).round().clamp(1, decoded.width - cropX);
  final rawCropHeight =
      (regionHeight * decoded.height).round().clamp(1, decoded.height - cropY);

  if (rawCropWidth < 6 || rawCropHeight < 6) return box;

  final rawCrop = img.copyCrop(
    decoded,
    x: cropX,
    y: cropY,
    width: rawCropWidth,
    height: rawCropHeight,
  );

  const maxWorkingDimension = 320;
  final largestSide = math.max(rawCrop.width, rawCrop.height);
  final scaleDown =
      largestSide > maxWorkingDimension ? maxWorkingDimension / largestSide : 1.0;

  final crop = scaleDown < 1.0
      ? img.copyResize(
          rawCrop,
          width: (rawCrop.width * scaleDown).round().clamp(1, rawCrop.width),
          height:
              (rawCrop.height * scaleDown).round().clamp(1, rawCrop.height),
        )
      : rawCrop;

  final cropWidth = crop.width;
  final cropHeight = crop.height;

  final gray = List.generate(cropHeight, (_) => List<double>.filled(cropWidth, 0));
  for (var y = 0; y < cropHeight; y++) {
    for (var x = 0; x < cropWidth; x++) {
      final pixel = crop.getPixel(x, y);
      gray[y][x] = (pixel.r + pixel.g + pixel.b) / 3.0;
    }
  }

  final mag = List.generate(cropHeight, (_) => List<double>.filled(cropWidth, 0));
  for (var y = 1; y < cropHeight - 1; y++) {
    for (var x = 1; x < cropWidth - 1; x++) {
      final gx = gray[y - 1][x + 1] +
          2 * gray[y][x + 1] +
          gray[y + 1][x + 1] -
          gray[y - 1][x - 1] -
          2 * gray[y][x - 1] -
          gray[y + 1][x - 1];
      final gy = gray[y + 1][x - 1] +
          2 * gray[y + 1][x] +
          gray[y + 1][x + 1] -
          gray[y - 1][x - 1] -
          2 * gray[y - 1][x] -
          gray[y - 1][x + 1];
      mag[y][x] = math.sqrt(gx * gx + gy * gy);
    }
  }

  final origLeft =
      (((box.x - regionX) / regionWidth) * cropWidth).round().clamp(0, cropWidth - 1);
  final origRight = ((((box.x + box.width) - regionX) / regionWidth) * cropWidth)
      .round()
      .clamp(0, cropWidth - 1);
  final origTop =
      (((box.y - regionY) / regionHeight) * cropHeight).round().clamp(0, cropHeight - 1);
  final origBottom = ((((box.y + box.height) - regionY) / regionHeight) * cropHeight)
      .round()
      .clamp(0, cropHeight - 1);

  final searchBandX = (cropWidth * 0.06).round().clamp(1, (cropWidth / 5).floor());
  final searchBandY = (cropHeight * 0.06).round().clamp(1, (cropHeight / 5).floor());

  double columnStrength(int x) {
    if (x < 0 || x >= cropWidth) return 0.0;
    var sum = 0.0;
    for (var y = origTop; y <= origBottom; y++) sum += mag[y][x];
    return sum;
  }

  double rowStrength(int y) {
    if (y < 0 || y >= cropHeight) return 0.0;
    var sum = 0.0;
    for (var x = origLeft; x <= origRight; x++) sum += mag[y][x];
    return sum;
  }

  int bestNear(int center, int band, double Function(int) strengthFn) {
    var bestPos = center;
    var bestVal = strengthFn(center);
    var runnerUpVal = 0.0;
    for (var d = -band; d <= band; d++) {
      if (d == 0) continue;
      final pos = center + d;
      final val = strengthFn(pos);
      if (val > bestVal) {
        runnerUpVal = bestVal;
        bestVal = val;
        bestPos = pos;
      } else if (val > runnerUpVal) {
        runnerUpVal = val;
      }
    }
    final originalVal = strengthFn(center);
    final isClearlyStrongerThanOriginal = originalVal > 0 && bestVal > originalVal * 1.7;
    final isClearPeak = runnerUpVal <= 0 || bestVal > runnerUpVal * 1.4;
    if (!isClearlyStrongerThanOriginal || !isClearPeak) return center;
    return bestPos;
  }

  final newLeft = bestNear(origLeft, searchBandX, columnStrength);
  final newRight = bestNear(origRight, searchBandX, columnStrength);
  final newTop = bestNear(origTop, searchBandY, rowStrength);
  final newBottom = bestNear(origBottom, searchBandY, rowStrength);

  if (newRight <= newLeft || newBottom <= newTop) return box;

  final snapped = BoundingBox(
    x: regionX + (newLeft / cropWidth) * regionWidth,
    y: regionY + (newTop / cropHeight) * regionHeight,
    width: ((newRight - newLeft) / cropWidth) * regionWidth,
    height: ((newBottom - newTop) / cropHeight) * regionHeight,
  );

  final validated = sanitizeLocalizedBox(snapped);
  if (validated == null) return box;

  final originalArea = box.width * box.height;
  final validatedArea = validated.width * validated.height;
  if (originalArea <= 0 ||
      validatedArea < originalArea * 0.65 ||
      validatedArea > originalArea * 1.35) {
    return box;
  }

  return validated;
}