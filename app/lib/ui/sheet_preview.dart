import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/render.dart';

/// Interactive, to-scale preview of one sheet. Uses the same painter as the
/// print renderer.
class SheetPreview extends StatefulWidget {
  const SheetPreview({
    super.key,
    required this.job,
    required this.sheet,
    required this.selected,
    required this.onSelect,
    required this.onChanged,
    this.showDesign = true,
    this.showTrim = true,
  });

  final PrintJob job;
  final int sheet;
  final PhotoSlot? selected;
  final ValueChanged<PhotoSlot?> onSelect;
  final VoidCallback onChanged;
  final bool showDesign, showTrim;

  @override
  State<SheetPreview> createState() => _SheetPreviewState();
}

class _SheetPreviewState extends State<SheetPreview> {
  double _scale = 1;
  double _startZoom = 1;
  Rect? _activeCell;

  (int, Rect)? _hit(Offset local) {
    final p = local / _scale;
    final rects = cellRects(widget.job);
    for (var i = 0; i < rects.length; i++) {
      if (rects[i].contains(p)) return (i, rects[i]);
    }
    return null;
  }

  PhotoSlot? _slotAt(int i) => cellSlots(widget.job, widget.sheet)[i];

  void _pan(PhotoSlot s, Rect cell, Offset deltaPx) {
    final r = photoRect(s, cell);
    final ox = (r.width - cell.width) / 2, oy = (r.height - cell.height) / 2;
    final d = deltaPx / _scale;
    s.pan = Offset(
      ox > 0 ? (s.pan.dx - d.dx / ox).clamp(-1.0, 1.0) : 0,
      oy > 0 ? (s.pan.dy - d.dy / oy).clamp(-1.0, 1.0) : 0,
    );
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.job.paper;
    return LayoutBuilder(builder: (context, c) {
      _scale = math.min(c.maxWidth / p.imageWidth, c.maxHeight / p.imageHeight);
      final size = Size(p.imageWidth * _scale, p.imageHeight * _scale);
      return Center(
        child: Listener(
          onPointerSignal: (e) {
            if (e is PointerScrollEvent) {
              final hit = _hit(e.localPosition);
              final s = hit == null ? null : _slotAt(hit.$1);
              if (s == null) return;
              s.zoom = (s.zoom * (e.scrollDelta.dy > 0 ? 0.95 : 1.05)).clamp(1.0, 6.0);
              widget.onSelect(s);
              widget.onChanged();
            }
          },
          child: GestureDetector(
            onTapUp: (d) {
              final hit = _hit(d.localPosition);
              widget.onSelect(hit == null ? null : _slotAt(hit.$1));
            },
            onScaleStart: (d) {
              final hit = _hit(d.localFocalPoint);
              final s = hit == null ? null : _slotAt(hit.$1);
              _activeCell = s == null ? null : hit!.$2;
              if (s != null) {
                _startZoom = s.zoom;
                if (s != widget.selected) widget.onSelect(s);
              }
            },
            onScaleUpdate: (d) {
              final s = widget.selected;
              final cell = _activeCell;
              if (s == null || cell == null) return;
              if (d.pointerCount > 1) s.zoom = (_startZoom * d.scale).clamp(1.0, 6.0);
              _pan(s, cell, d.focalPointDelta);
            },
            child: Container(
              width: size.width,
              height: size.height,
              decoration: BoxDecoration(boxShadow: [
                BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 12, offset: const Offset(0, 4)),
              ]),
              child: CustomPaint(
                size: size,
                painter: _SheetPainter(widget.job, widget.sheet, _scale, widget.selected, widget.showDesign,
                    widget.showTrim, Theme.of(context).colorScheme.primary),
              ),
            ),
          ),
        ),
      );
    });
  }
}

class _SheetPainter extends CustomPainter {
  _SheetPainter(this.job, this.sheet, this.scale, this.selected, this.showDesign, this.showTrim, this.accent);
  final PrintJob job;
  final int sheet;
  final double scale;
  final PhotoSlot? selected;
  final bool showDesign, showTrim;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final p = job.paper;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.scale(scale);
    paintSheet(canvas, job, sheet);
    if (showDesign && job.hasDesign) {
      paintDesign(canvas, job, ink: const Color(0x8CFFFFFF));
      paintDesign(canvas, job, ink: const Color(0x30000000)); // keeps it visible on light photos
    }
    final paperRect = Rect.fromLTWH(p.bleedX.toDouble(), p.bleedY.toDouble(), p.paperWidth.toDouble(), p.paperHeight.toDouble());
    if (showTrim) {
      final full = Rect.fromLTWH(0, 0, p.imageWidth.toDouble(), p.imageHeight.toDouble());
      canvas.drawPath(
        Path()
          ..fillType = PathFillType.evenOdd
          ..addRect(full)
          ..addRect(paperRect),
        Paint()..color = const Color(0x99000000),
      );
    }
    final sel = selected;
    if (sel != null) {
      final rects = cellRects(job);
      final slots = cellSlots(job, sheet);
      for (var i = 0; i < rects.length; i++) {
        if (identical(slots[i], sel)) {
          canvas.drawRect(
            rects[i].intersect(paperRect).deflate(2 / scale),
            Paint()
              ..color = accent
              ..style = PaintingStyle.stroke
              ..strokeWidth = 3 / scale,
          );
        }
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
