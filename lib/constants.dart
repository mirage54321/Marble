import 'package:flutter/material.dart';

const TealScan      = Color(0xFF00B3AC);
const TealScanLight = Color(0xFFE0F7F6);
const TealScanDark  = Color(0xFF008C86);
const TealScanText  = Color(0xFF005C59);

enum ScanStatus { ok, warning, critical }

class StatusColors {
  final Color background;
  final Color text;
  const StatusColors(this.background, this.text);
}

StatusColors statusColors(ScanStatus status) {
  switch (status) {
    case ScanStatus.ok:
      return const StatusColors(TealScanLight, TealScanText);
    case ScanStatus.warning:
      return const StatusColors(Color(0xFFFFF3E0), Color(0xFF7B4500));
    case ScanStatus.critical:
      return const StatusColors(Color(0xFFFFEBEE), Color(0xFF7B1010));
  }
}

class BoundingBox {
  final double x;
  final double y;
  final double width;
  final double height;

  const BoundingBox({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  factory BoundingBox.fromBox2D(List<dynamic> box2d) {
    double scale(dynamic v) {
      if (v == null) return 0.0;
      final n = (v as num).toDouble();
      return (n / 1000.0).clamp(0.0, 1.0);
    }

    final yMin = scale(box2d[0]);
    final xMin = scale(box2d[1]);
    final yMax = scale(box2d[2]);
    final xMax = scale(box2d[3]);

    return BoundingBox(
      x: xMin,
      y: yMin,
      width: (xMax - xMin).clamp(0.0, 1.0),
      height: (yMax - yMin).clamp(0.0, 1.0),
    );
  }
}

class Finding {
  final String title;
  final String description;
  final ScanStatus severity;
  BoundingBox? box;
  bool isReported;
  bool isBoxRefined;

  Finding({
    required this.title,
    required this.description,
    required this.severity,
    this.box,
    this.isReported = false,
    this.isBoxRefined = false,
  });

  factory Finding.fromJson(Map<String, dynamic> json) {
    ScanStatus severity;
    switch ((json['severity'] as String).toLowerCase().trim()) {
      case 'critical':
        severity = ScanStatus.critical;
        break;
      case 'warning':
        severity = ScanStatus.warning;
        break;
      default:
        severity = ScanStatus.ok;
    }

    BoundingBox? box;
    final box2d = json['box_2d'];
    if (box2d is List && box2d.length == 4) {
      try {
        box = BoundingBox.fromBox2D(box2d);
      } catch (_) {
        box = null;
      }
    }

    return Finding(
      title: json['title'] as String? ?? 'Unknown',
      description: json['description'] as String? ?? '',
      severity: severity,
      box: box,
    );
  }
}