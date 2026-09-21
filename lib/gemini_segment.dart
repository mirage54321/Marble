import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

import 'ai_scan.dart' show boxOverlapRatio, severityRank;
import 'connectivity_check.dart';
import 'constants.dart';
import 'retry_helper.dart';

const String _base = 'https://ridgeboticsapp.onrender.com';

const int _maxCropSide = 1024;

const int _maxMaskSide = 256;


Future<void> segmentFindings(
  Uint8List imageBytes,
  List<Finding> findings, {
  int maxItems = 6,
  Future<void> Function(int index, SegMask mask)? onMask,
}) async {
  if (!ConnectivityCheck.isOnline) return;

  final candidates = <int>[];
  for (var i = 0; i < findings.length; i++) {
    final f = findings[i];
    if (f.box == null || f.severity == ScanStatus.ok) continue;
    if (f.title.toLowerCase().contains('photo quality')) continue;
    candidates.add(i);
  }
  candidates.sort((a, b) =>
      severityRank(findings[b].severity) - severityRank(findings[a].severity));

  final photo = img.decodeImage(imageBytes);
  if (photo == null) return;

  for (final i in candidates.take(maxItems)) {
    SegMask? mask;
    try {
      mask = await withBackoffRetry<SegMask?>(
        () => _segmentOnce(photo, findings[i]),
        maxAttempts: 2,
        initialDelay: const Duration(seconds: 2),
        isRetryable: (e) => e.toString().contains('experiencing high demand'),
      );
    } catch (_) {
      mask = null;
    }
    if (mask != null && onMask != null) await onMask(i, mask);
  }
}

Future<SegMask?> _segmentOnce(img.Image photo, Finding finding) async {
  final box = finding.box!;

  final pad = math.max(box.width, box.height) * 0.3;
  final left = (box.x - pad).clamp(0.0, 1.0);
  final top = (box.y - pad).clamp(0.0, 1.0);
  final right = (box.x + box.width + pad).clamp(0.0, 1.0);
  final bottom = (box.y + box.height + pad).clamp(0.0, 1.0);

  final cx = (left * photo.width).round().clamp(0, photo.width - 1);
  final cy = (top * photo.height).round().clamp(0, photo.height - 1);
  final cw = ((right - left) * photo.width).round().clamp(1, photo.width - cx);
  final ch =
      ((bottom - top) * photo.height).round().clamp(1, photo.height - cy);

  final regionX = cx / photo.width;
  final regionY = cy / photo.height;
  final regionW = cw / photo.width;
  final regionH = ch / photo.height;

  var crop = img.copyCrop(photo, x: cx, y: cy, width: cw, height: ch);
  if (math.max(crop.width, crop.height) > _maxCropSide) {
    crop = img.copyResize(
      crop,
      width: crop.width >= crop.height ? _maxCropSide : null,
      height: crop.height > crop.width ? _maxCropSide : null,
    );
  }
  final cropJpeg = base64Encode(img.encodeJpg(crop, quality: 90));

  final prompt = 'This is a cropped photo of part of an FRC robot. Give the '
      'segmentation mask for this one specific item:\n\n'
      'Title: ${finding.title}\n'
      'Description: ${finding.description}\n\n'
      'Output a JSON list with a single entry containing the 2D bounding '
      'box in the key "box_2d" as [ymin, xmin, ymax, xmax] normalized to '
      '0-1000, the segmentation mask in the key "mask", and a short text '
      'label in the key "label". The mask must cover only the actual pixels '
      'of that item, not the surrounding parts of the robot. If the item is '
      'not visible in this crop, output [].';

  final body = {
    'contents': [
      {
        'parts': [
          {'text': prompt},
          {
            'inline_data': {'mime_type': 'image/jpeg', 'data': cropJpeg}
          },
        ]
      }
    ],
    'generationConfig': {
      'temperature': 0,
      'maxOutputTokens': 8192,
      'responseMimeType': 'application/json',
      'thinkingConfig': {'thinkingBudget': 0},
    },
  };

  final response = await http
      .post(
        Uri.parse('$_base/analyzeImage'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      )
      .timeout(const Duration(seconds: 45));

  final data = jsonDecode(response.body) as Map<String, dynamic>;
  if (response.statusCode != 200) {
    final msg = (data['error']?.toString() ?? '').toLowerCase();
    if (msg.contains('quota') ||
        msg.contains('429') ||
        msg.contains('rate limit') ||
        msg.contains('resource_exhausted')) {
      throw Exception('experiencing high demand');
    }
    return null;
  }

  final raw = _extractText(data);
  if (raw == null || raw.isEmpty) return null;
  try {
    final parsed = jsonDecode(raw);
    final List<dynamic> items = parsed is List
        ? parsed
        : (parsed is Map ? (parsed['items'] as List<dynamic>? ?? []) : []);
    if (items.isEmpty) return null;

    final item = items.first as Map<String, dynamic>;
    final box2d = item['box_2d'] as List<dynamic>?;
    final maskStr = item['mask'] as String?;
    if (box2d == null || box2d.length != 4 || maskStr == null) return null;

    final cropBox = BoundingBox.fromBox2D(box2d);
    final boxPxW = cropBox.width * crop.width;
    final boxPxH = cropBox.height * crop.height;
    if (boxPxW < 4 || boxPxH < 4) return null;

    var b64 = maskStr;
    final comma = b64.indexOf(',');
    if (b64.startsWith('data:') && comma != -1) b64 = b64.substring(comma + 1);
    final decoded = img.decodeImage(base64Decode(b64));
    if (decoded == null) return null;

    final longest = math.max(boxPxW, boxPxH);
    final scale = math.min(_maxMaskSide.toDouble(), longest) / longest;
    final mw = math.max(1, (boxPxW * scale).round());
    final mh = math.max(1, (boxPxH * scale).round());
    final resized = img.copyResize(decoded,
        width: mw, height: mh, interpolation: img.Interpolation.linear);

    final grayscale = resized.numChannels <= 2;
    final inside = Uint8List(mw * mh);
    var minX = mw, minY = mh, maxX = -1, maxY = -1, count = 0;
    for (var y = 0; y < mh; y++) {
      for (var x = 0; x < mw; x++) {
        final p = resized.getPixel(x, y);
        final v = grayscale ? p.r.toDouble() : (p.r + p.g + p.b) / 3.0;
        if (v > 127) {
          inside[y * mw + x] = 255;
          count++;
          if (x < minX) minX = x;
          if (y < minY) minY = y;
          if (x > maxX) maxX = x;
          if (y > maxY) maxY = y;
        }
      }
    }

    if (maxX < minX || maxY < minY) return null;
    if (count / (mw * mh) < 0.03) return null;

    final tw = maxX - minX + 1;
    final th = maxY - minY + 1;
    final trimmed = Uint8List(tw * th);
    for (var y = 0; y < th; y++) {
      for (var x = 0; x < tw; x++) {
        trimmed[y * tw + x] = inside[(minY + y) * mw + (minX + x)];
      }
    }

    final tightInCrop = BoundingBox(
      x: cropBox.x + (minX / mw) * cropBox.width,
      y: cropBox.y + (minY / mh) * cropBox.height,
      width: (tw / mw) * cropBox.width,
      height: (th / mh) * cropBox.height,
    );
    final fullBox = BoundingBox(
      x: regionX + tightInCrop.x * regionW,
      y: regionY + tightInCrop.y * regionH,
      width: tightInCrop.width * regionW,
      height: tightInCrop.height * regionH,
    );

    if (boxOverlapRatio(fullBox, box) < 0.25) return null;

    return SegMask(box: fullBox, width: tw, height: th, alpha: trimmed);
  } catch (_) {
    return null;
  }
}

String? _extractText(Map<String, dynamic> data) {
  try {
    final candidates = data['candidates'] as List<dynamic>?;
    final text = candidates?[0]['content']['parts'][0]['text'] as String?;
    return text?.replaceAll('```json', '').replaceAll('```', '').trim();
  } catch (_) {
    return null;
  }
}