import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'tap_cursor.dart';
import 'constants.dart';
import 'ai_scan.dart';
import 'scan_screen.dart';
import 'gemini_segment.dart';

class ResultsScreen extends StatefulWidget {
  final Uint8List imageBytes;
  final List<Finding> findings;
  final String scanMode;

  const ResultsScreen({
    super.key,
    required this.imageBytes,
    required this.findings,
    this.scanMode = 'physical',
  });

  @override
  State<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends State<ResultsScreen> {
  int? _highlightedIndex;
  late final String _scanId;

  late final Future<ui.Image> _decodedImage;
  final Map<int, _MaskOverlay> _overlays = {};
  bool _segmenting = false;

  @override
  void initState() {
    super.initState();
    _scanId = 'scan_${DateTime.now().microsecondsSinceEpoch}';
    _decodedImage = _decodeImage(widget.imageBytes);
    _segmenting = widget.findings.any((f) => f.box != null);
    if (_segmenting) unawaited(_runSegmentation());
  }

  Future<void> _runSegmentation() async {
    try {
      await segmentFindings(
        widget.imageBytes,
        findings,
        onMask: (index, mask) async {
          final overlay =
              await _buildOverlay(mask, _severityColor(findings[index].severity));
          if (!mounted) return;
          setState(() {
            findings[index].mask = mask;
            findings[index].box = mask.box;
            findings[index].isBoxRefined = true;
            _overlays[index] = overlay;
          });
        },
      );
    } catch (_) {
    } finally {
      if (mounted) setState(() => _segmenting = false);
    }
  }

  Future<ui.Image> _pixelsToImage(Uint8List rgba, int w, int h) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, completer.complete);
    return completer.future;
  }

  Future<_MaskOverlay> _buildOverlay(SegMask m, Color color) async {
    final w = m.width, h = m.height;
    bool on(int x, int y) =>
        x >= 0 && y >= 0 && x < w && y < h && m.alpha[y * w + x] > 127;

    final cr = (color.r * 255).round();
    final cg = (color.g * 255).round();
    final cb = (color.b * 255).round();

    final fill = Uint8List(w * h * 4);
    final edge = Uint8List(w * h * 4);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        if (!on(x, y)) continue;
        final i = (y * w + x) * 4;
        fill[i] = cr; fill[i + 1] = cg; fill[i + 2] = cb; fill[i + 3] = 255;
        final isEdge =
            !on(x - 2, y) || !on(x + 2, y) || !on(x, y - 2) || !on(x, y + 2);
        if (isEdge) {
          edge[i] = cr; edge[i + 1] = cg; edge[i + 2] = cb; edge[i + 3] = 255;
        }
      }
    }
    return _MaskOverlay(
      await _pixelsToImage(fill, w, h),
      await _pixelsToImage(edge, w, h),
    );
  }

  Future<ui.Image> _decodeImage(Uint8List bytes) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromList(bytes, completer.complete);
    return completer.future;
  }

  List<Finding> get findings => widget.findings;

  int get _criticalCount =>
      findings.where((f) => f.severity == ScanStatus.critical).length;
  int get _warningCount =>
      findings.where((f) => f.severity == ScanStatus.warning).length;
  int get _okCount =>
      findings.where((f) => f.severity == ScanStatus.ok).length;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const ui.Color.fromARGB(255, 219, 219, 219),
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(context),
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    photor(),
                    answers(),
                    thingsFound('What the AI found'),
                    ...findings.asMap().entries.map(
                          (e) => _buildFinding(
                            index: e.key,
                            number: '${e.key + 1}',
                            finding: e.value,
                          ),
                        ),
                    _buildActions(context),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      child: Row(
        children: [
          TapCursor(
            onTap: () => Navigator.pop(context),
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: Color.fromARGB(255, 161, 161, 161),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.arrow_back,
                  color: Color.fromARGB(255, 255, 255, 255), size: 17),
            ),
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Text('Scan results',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
          ),
          Text(
            _formattedTime(),
            style: TextStyle(
                fontSize: 12, color: Color.fromARGB(255, 161, 161, 161)),
          ),
        ],
      ),
    );
  }

  Widget photor() {
    return TapCursor(
      onTap: () => setState(() => _highlightedIndex = null),
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        height: 280,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          color: const Color(0xFF1C2B2B),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: FutureBuilder<ui.Image>(
            future: _decodedImage,
            builder: (context, snapshot) {
              return LayoutBuilder(
                builder: (context, constraints) {
                  final containerSize =
                      Size(constraints.maxWidth, constraints.maxHeight);
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.memory(
                        widget.imageBytes,
                        fit: BoxFit.contain,
                        width: double.infinity,
                      ),
                      if (_segmenting)
                        Positioned(
                          top: 8,
                          right: 8,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.55),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox(
                                  width: 10,
                                  height: 10,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 1.5, color: Colors.white),
                                ),
                                SizedBox(width: 6),
                                Text('Refining outlines…',
                                    style: TextStyle(
                                        color: Colors.white, fontSize: 10)),
                              ],
                            ),
                          ),
                        ),
                      if (snapshot.hasData)
                        CustomPaint(
                          size: containerSize,
                          painter: _BoxPainter(
                            findings: findings,
                            highlightedIndex: _highlightedIndex,
                            overlays: _overlays,
                            maskVersion: _overlays.length,
                            imageSize: Size(
                              snapshot.data!.width.toDouble(),
                              snapshot.data!.height.toDouble(),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }

  Widget answers() {
    final hasIssues = _criticalCount + _warningCount > 0;
    final total = _criticalCount + _warningCount;
    final iconColor = _criticalCount > 0
        ? const Color(0xFFD93025)
        : _warningCount > 0
            ? const Color(0xFFE8A000)
            : Color.fromARGB(255, 161, 161, 161);
    final bgColor = _criticalCount > 0
        ? const Color(0xFFFFEBEE)
        : _warningCount > 0
            ? const Color(0xFFFFF3E0)
            : Color.fromARGB(255, 199, 205, 205);
    final icon = _criticalCount > 0
        ? Icons.warning_amber_rounded
        : _warningCount > 0
            ? Icons.info_outline
            : Icons.check_circle_outline;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: Colors.black.withValues(alpha: 0.07), width: 0.5),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(icon, color: iconColor, size: 22),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                hasIssues
                    ? '$total issue${total > 1 ? 's' : ''} found'
                    : 'All clear!',
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 2),
              Text(
                '$_criticalCount critical · $_warningCount warning · $_okCount ok',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget thingsFound(String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
      child: Text(label,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
    );
  }

  Widget _buildFinding({
    required int index,
    required String number,
    required Finding finding,
  }) {
    final colors = statusColors(finding.severity);
    final badgeLabel = finding.severity == ScanStatus.critical
        ? 'Critical'
        : finding.severity == ScanStatus.warning
            ? 'Warning'
            : 'All clear';
    final isHighlighted = _highlightedIndex == index;

    return TapCursor(
      onTap: finding.box == null
          ? null
          : () => setState(() {
                _highlightedIndex = isHighlighted ? null : index;
              }),
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isHighlighted
                ? colors.text.withValues(alpha: 0.6)
                : Colors.black.withValues(alpha: 0.07),
            width: isHighlighted ? 1.5 : 0.5,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 26,
                  height: 26,
                  margin: const EdgeInsets.only(top: 1),
                  decoration: BoxDecoration(
                    color: colors.background,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Text(number,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: colors.text)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(finding.title,
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w500)),
                      const SizedBox(height: 3),
                      Text(finding.description,
                          style: TextStyle(
                              fontSize: 12,
                              color: Color.fromARGB(255, 161, 161, 161),
                              height: 1.5)),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: colors.background,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(badgeLabel,
                                style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w500,
                                    color: colors.text)),
                          ),
                          if (finding.box != null) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: Colors.grey.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.my_location,
                                      size: 11, color: Colors.grey[600]),
                                  const SizedBox(width: 3),
                                  Text(
                                    isHighlighted
                                        ? 'Showing on photo'
                                        : 'Show on photo',
                                    style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w500,
                                        color: Colors.grey[600]),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: finding.isReported
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.check_circle,
                            size: 13, color: Colors.grey[500]),
                        const SizedBox(width: 4),
                        Text('Reported',
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                                color: Colors.grey[500])),
                      ],
                    )
                  : TapCursor(
                      onTap: () => _reportFinding(index, finding),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.flag_outlined,
                              size: 13, color: Colors.grey[500]),
                          const SizedBox(width: 4),
                          Text('Report an error',
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                  color: Colors.grey[500])),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _reportFinding(int index, Finding finding) async {
    final report = await showDialog<_ReportDetails>(
      context: context,
      builder: (_) => _ReportDialog(title: finding.title),
    );
    if (report == null || !mounted) return;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      await AiService.reportFinding(
        scanId: _scanId,
        findingId: 'finding_${index + 1}',
        finding: finding,
        errorType: report.errorType,
        userComment: report.comment,
        scanMode: widget.scanMode,
      );
      if (!mounted) return;
      setState(() => finding.isReported = true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Thanks! Your report was submitted.')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not submit report. Please try again.')),
      );
    } finally {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }
  }

  Widget _buildActions(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Row(
        children: [
          Expanded(
            child: TapCursor(
              onTap: () => Navigator.pushReplacement(
                context,
                MaterialPageRoute(builder: (_) => const ScanScreen()),
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 13),
                decoration: BoxDecoration(
                  color: Color.fromARGB(255, 161, 161, 161),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.camera_alt_outlined,
                        color: Colors.white, size: 16),
                    SizedBox(width: 7),
                    Text('Scan again',
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: Colors.white)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formattedTime() {
    final now = DateTime.now();
    return '${now.hour}:${now.minute.toString().padLeft(2, '0')}';
  }
}

Color _severityColor(ScanStatus s) => s == ScanStatus.critical
    ? const Color(0xFFD93025)
    : s == ScanStatus.warning
        ? const Color(0xFFE8A000)
        : const Color(0xFF00B3AC);

class _MaskOverlay {
  final ui.Image fill;
  final ui.Image edge;
  const _MaskOverlay(this.fill, this.edge);
}

class _BoxPainter extends CustomPainter {
  final List<Finding> findings;
  final int? highlightedIndex;
  final Size imageSize;
  final Map<int, _MaskOverlay> overlays;
  final int maskVersion;

  _BoxPainter({
    required this.findings,
    required this.highlightedIndex,
    required this.imageSize,
    required this.overlays,
    required this.maskVersion,
  });

  Rect _containedImageRect(Size containerSize) {
    final imageAspect = imageSize.width / imageSize.height;
    final containerAspect = containerSize.width / containerSize.height;

    double renderWidth, renderHeight;
    if (imageAspect > containerAspect) {
      renderWidth = containerSize.width;
      renderHeight = renderWidth / imageAspect;
    } else {
      renderHeight = containerSize.height;
      renderWidth = renderHeight * imageAspect;
    }

    final left = (containerSize.width - renderWidth) / 2;
    final top = (containerSize.height - renderHeight) / 2;
    return Rect.fromLTWH(left, top, renderWidth, renderHeight);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final imageRect = _containedImageRect(size);

    for (var i = 0; i < findings.length; i++) {
      final finding = findings[i];
      final box = finding.box;
      if (box == null) continue;

      final isDimmed = highlightedIndex != null && highlightedIndex != i;
      final color = _severityColor(finding.severity);
      final overlay = overlays[i];

      Rect labelRect;

      if (overlay != null) {
        final dst = Rect.fromLTWH(
          imageRect.left + box.x * imageRect.width,
          imageRect.top + box.y * imageRect.height,
          box.width * imageRect.width,
          box.height * imageRect.height,
        );
        final src = Rect.fromLTWH(0, 0, overlay.fill.width.toDouble(),
            overlay.fill.height.toDouble());

        canvas.drawImageRect(
          overlay.fill,
          src,
          dst,
          Paint()
            ..filterQuality = FilterQuality.medium
            ..color = Color.fromRGBO(0, 0, 0, isDimmed ? 0.08 : 0.30),
        );
        canvas.drawImageRect(
          overlay.edge,
          src,
          dst,
          Paint()
            ..filterQuality = FilterQuality.medium
            ..color = Color.fromRGBO(0, 0, 0, isDimmed ? 0.35 : 1.0),
        );
        labelRect = dst;
      } else {
        final rect = Rect.fromLTWH(
          imageRect.left + box.x * imageRect.width,
          imageRect.top + box.y * imageRect.height,
          box.width * imageRect.width,
          box.height * imageRect.height,
        ).inflate(4);

        final paint = Paint()
          ..color = isDimmed ? color.withValues(alpha: 0.25) : color
          ..style = PaintingStyle.stroke
          ..strokeWidth = isDimmed ? 1.5 : 2.5;
        canvas.drawRRect(
            RRect.fromRectAndRadius(rect, const Radius.circular(6)), paint);
        labelRect = rect;
      }

      if (!isDimmed) {
        final labelPainter = TextPainter(
          text: TextSpan(
            text: '${i + 1}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();

        final labelTop = (labelRect.top - 18) < imageRect.top
            ? labelRect.top
            : labelRect.top - 18;

        final labelBgRect = Rect.fromLTWH(
          labelRect.left,
          labelTop,
          labelPainter.width + 10,
          18,
        );
        canvas.drawRRect(
          RRect.fromRectAndCorners(labelBgRect,
              topLeft: const Radius.circular(4),
              topRight: const Radius.circular(4),
              bottomRight: const Radius.circular(4)),
          Paint()..color = color,
        );
        labelPainter.paint(
          canvas,
          Offset(labelBgRect.left + 5, labelBgRect.top + 3),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _BoxPainter oldDelegate) {
    return oldDelegate.highlightedIndex != highlightedIndex ||
        oldDelegate.findings != findings ||
        oldDelegate.imageSize != imageSize ||
        oldDelegate.maskVersion != maskVersion;
  }
}

class _ReportDetails {
  final String errorType;
  final String comment;

  const _ReportDetails(this.errorType, this.comment);
}

class _ReportDialog extends StatefulWidget {
  final String title;

  const _ReportDialog({required this.title});

  @override
  State<_ReportDialog> createState() => _ReportDialogState();
}

class _ReportDialogState extends State<_ReportDialog> {
  String _errorType = 'false_positive';
  final _commentController = TextEditingController();

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const options = {
      'false_positive': 'Not actually a problem',
      'wrong_location': 'Wrong location',
      'wrong_description': 'Incorrect description',
      'missed_problem': 'Missed a problem',
      'other': 'Other',
    };

    return AlertDialog(
      title: const Text('Report this finding'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('What is wrong with "${widget.title}"?'),
            const SizedBox(height: 8),
            for (final option in options.entries)
              RadioListTile<String>(
                contentPadding: EdgeInsets.zero,
                value: option.key,
                groupValue: _errorType,
                title: Text(option.value),
                onChanged: (value) => setState(() => _errorType = value!),
              ),
            TextField(
              controller: _commentController,
              maxLength: 500,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Additional information (optional)',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            _ReportDetails(_errorType, _commentController.text.trim()),
          ),
          child: const Text('Submit report'),
        ),
      ],
    );
  }
}