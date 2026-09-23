import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

import 'ai_scan.dart' show boxOverlapRatio, severityRank;
import 'connectivity_check.dart';
import 'constants.dart';

const String _base = 'https://ridgeboticsapp.onrender.com';

const int _maxPhotoSide = 1400;

const int _maxMaskSide = 256;

Future<void> segmentFindings(
  Uint8List imageBytes,
  List<Finding> findings, {
  int maxItems = 4,
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

  final selected = candidates.take(maxItems).toList();
  if (selected.isEmpty) return;

  final photo = img.decodeImage(imageBytes);
  if (photo == null) return;

  debugPrint('[segment] batching ${selected.length} finding(s) into 1 call');

  Map<int, SegMask>? masks;
  try {
    masks = await _segmentBatch(photo, selected, findings);
  } catch (e) {
    debugPrint('[segment] batch call failed: $e');
    return;
  }
  if (masks == null) return;

  for (final entry in masks.entries) {
    if (onMask != null) await onMask(entry.key, entry.value);
  }
}

Future<Map<int, SegMask>?> _segmentBatch(
  img.Image photo,
  List<int> selected,
  List<Finding> findings,
) async {
  var working = photo;
  if (math.max(photo.width, photo.height) > _maxPhotoSide) {
    working = img.copyResize(
      photo,
      width: photo.width >= photo.height ? _maxPhotoSide : null,
      height: photo.height > photo.width ? _maxPhotoSide : null,
    );
  }
  final photoJpeg = base64Encode(img.encodeJpg(working, quality: 90));

  final itemsDesc = StringBuffer();
  for (var i = 0; i < selected.length; i++) {
    final f = findings[selected[i]];
    final b = f.box!;
    final box1000 = [
      (b.y * 1000).round(),
      (b.x * 1000).round(),
      ((b.y + b.height) * 1000).round(),
      ((b.x + b.width) * 1000).round(),
    ];
    itemsDesc.writeln('${i + 1}. Title: ${f.title}');
    itemsDesc.writeln('   Description: ${f.description}');
    itemsDesc.writeln('   Approximate location box_2d: $box1000');
  }

  final prompt = 'This is a photo of an FRC robot. Below is a numbered list '
      'of ${selected.length} specific items already flagged on this robot, '
      'each with an approximate location. For EACH numbered item, give a '
      'tight segmentation mask of that exact item.\n\n'
      '${itemsDesc.toString()}\n'
      'Respond with a JSON array of exactly ${selected.length} objects, in '
      'the same order as the numbered list above (the first object '
      'corresponds to item 1, the second to item 2, and so on). Each object '
      'must have "box_2d" as [ymin, xmin, ymax, xmax] normalized 0-1000 '
      'relative to the full photo, and "mask" as the standard segmentation '
      'mask image for that item. The mask must cover only the actual pixels '
      'of that specific item, not surrounding parts of the robot. If you '
      'cannot confidently locate a numbered item in the photo, still '
      'include its object in the array but set "box_2d" and "mask" to '
      'null. Do not skip or merge items; the array length must always '
      'equal ${selected.length}.';

  final body = {
    'contents': [
      {
        'parts': [
          {'text': prompt},
          {
            'inline_data': {'mime_type': 'image/jpeg', 'data': photoJpeg}
          },
        ]
      }
    ],
    'generationConfig': {
      'temperature': 0,
      'maxOutputTokens': 16384,
      'responseMimeType': 'application/json',
      'thinkingConfig': {'thinkingBudget': 0},
    },
  };

  final response = await http
      .post(
        Uri.parse('$_base/segmentImage'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      )
      .timeout(const Duration(seconds: 60));

  final data = jsonDecode(response.body) as Map<String, dynamic>;
  if (response.statusCode != 200) {
    final msg = (data['error']?.toString() ?? '').toLowerCase();
    debugPrint('[segment] batch HTTP ${response.statusCode}: $msg');
    return null;
  }

  final raw = _extractText(data);
  if (raw == null || raw.isEmpty) {
    debugPrint('[segment] batch: empty/unparseable response text');
    return null;
  }

  final results = <int, SegMask>{};
  try {
    final parsed = jsonDecode(raw);
    final List<dynamic> items = parsed is List
        ? parsed
        : (parsed is Map ? (parsed['items'] as List<dynamic>? ?? []) : []);

    for (var i = 0; i < selected.length && i < items.length; i++) {
      final findingIndex = selected[i];
      final finding = findings[findingIndex];
      final item = items[i];
      if (item is! Map<String, dynamic>) continue;

      final box2d = item['box_2d'] as List<dynamic>?;
      final maskStr = item['mask'] as String?;
      if (box2d == null || box2d.length != 4 || maskStr == null) {
        debugPrint('[segment] "${finding.title}" no mask returned for this item');
        continue;
      }

      final maskBox = BoundingBox.fromBox2D(box2d);
      final boxPxW = maskBox.width * working.width;
      final boxPxH = maskBox.height * working.height;
      if (boxPxW < 4 || boxPxH < 4) {
        debugPrint('[segment] "${finding.title}" box too small '
            '(${boxPxW.toStringAsFixed(1)}x${boxPxH.toStringAsFixed(1)}px)');
        continue;
      }

      var b64 = maskStr;
      final comma = b64.indexOf(',');
      if (b64.startsWith('data:') && comma != -1) b64 = b64.substring(comma + 1);
      final decoded = img.decodeImage(base64Decode(b64));
      if (decoded == null) {
        debugPrint('[segment] "${finding.title}" could not decode mask PNG');
        continue;
      }

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

      if (maxX < minX || maxY < minY) {
        debugPrint('[segment] "${finding.title}" mask thresholded to nothing');
        continue;
      }
      if (count / (mw * mh) < 0.03) {
        debugPrint('[segment] "${finding.title}" mask covers only '
            '${(count / (mw * mh) * 100).toStringAsFixed(1)}%, rejecting');
        continue;
      }

      final tw = maxX - minX + 1;
      final th = maxY - minY + 1;
      final trimmed = Uint8List(tw * th);
      for (var y = 0; y < th; y++) {
        for (var x = 0; x < tw; x++) {
          trimmed[y * tw + x] = inside[(minY + y) * mw + (minX + x)];
        }
      }

      final fullBox = BoundingBox(
        x: maskBox.x + (minX / mw) * maskBox.width,
        y: maskBox.y + (minY / mh) * maskBox.height,
        width: (tw / mw) * maskBox.width,
        height: (th / mh) * maskBox.height,
      );

      final overlap = boxOverlapRatio(fullBox, finding.box!);
      if (overlap < 0.25) {
        debugPrint('[segment] "${finding.title}" mask barely overlaps original '
            '(${(overlap * 100).toStringAsFixed(1)}%), rejecting');
        continue;
      }

      debugPrint('[segment] "${finding.title}" OK, overlap '
          '${(overlap * 100).toStringAsFixed(0)}%');
      results[findingIndex] = SegMask(box: fullBox, width: tw, height: th, alpha: trimmed);
    }
  } catch (e, st) {
    debugPrint('[segment] batch parse threw: $e\n$st');
    return results.isEmpty ? null : results;
  }

  return results;
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