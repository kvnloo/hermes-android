// A deterministic, single-frame snapshot of the chat viewport with ink.
// Adapted from Dash app/src/components/annotate/composite.ts at
// 1e577218da34a2a72e1575c2c7768a2c4d509498.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../controllers/annotation_controller.dart';
import '../models/annotation_ink.dart';
import '../widgets/ink_overlay.dart';

typedef AnnotationBoundaryCapture = Future<ui.Image> Function(
  RenderRepaintBoundary boundary,
  double pixelRatio,
);

/// Captures content below InkOverlay, then draws the very same InkPainter
/// into that image; the toolbar and OS chrome are intentionally not captured.
class AnnotationSnapshotCapture {
  const AnnotationSnapshotCapture({this.captureBoundary});

  /// A controlled boundary seam for widget tests; production uses toImage.
  final AnnotationBoundaryCapture? captureBoundary;

  Future<Uint8List> capture({
    required GlobalKey boundaryKey,
    required Drawing drawing,
    required Color accent,
    required Color red,
    required Color eraserColor,
    LiveInk? live,
    double pixelRatio = 1,
  }) async {
    final renderObject = boundaryKey.currentContext?.findRenderObject();
    if (renderObject is! RenderRepaintBoundary ||
        !renderObject.hasSize ||
        renderObject.size.isEmpty) {
      throw StateError('The chat viewport is not ready for a screenshot.');
    }
    // debugNeedsPaint is a debug-only getter. Never evaluate it in release.
    assert(() {
      if (renderObject.debugNeedsPaint) {
        throw StateError('The chat viewport is not ready for a screenshot.');
      }
      return true;
    }());
    if (!pixelRatio.isFinite || pixelRatio <= 0 || pixelRatio > 4) {
      throw StateError('Invalid annotation screenshot scale.');
    }
    final logicalSize = renderObject.size;
    final plannedWidth = (logicalSize.width * pixelRatio).ceil();
    final plannedHeight = (logicalSize.height * pixelRatio).ceil();
    if (plannedWidth <= 0 ||
        plannedHeight <= 0 ||
        plannedWidth * plannedHeight > 24 * 1024 * 1024) {
      throw StateError('The annotation screenshot is too large.');
    }

    final screenshot = await (captureBoundary ?? _captureBoundary)(
      renderObject,
      pixelRatio,
    );
    ui.Picture? picture;
    ui.Image? composited;
    try {
      if (screenshot.width <= 0 ||
          screenshot.height <= 0 ||
          screenshot.width * screenshot.height > 24 * 1024 * 1024) {
        throw StateError('Invalid annotation screenshot dimensions.');
      }
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.scale(
        screenshot.width / logicalSize.width,
        screenshot.height / logicalSize.height,
      );
      canvas.drawImageRect(
        screenshot,
        ui.Rect.fromLTWH(
          0,
          0,
          screenshot.width.toDouble(),
          screenshot.height.toDouble(),
        ),
        ui.Offset.zero & logicalSize,
        ui.Paint(),
      );
      InkPainter(
        drawing: drawing,
        live: live,
        accent: accent,
        red: red,
        eraserColor: eraserColor,
      ).paint(canvas, logicalSize);
      picture = recorder.endRecording();
      composited = await picture.toImage(screenshot.width, screenshot.height);
      final data = await composited.toByteData(format: ui.ImageByteFormat.png);
      if (data == null || data.lengthInBytes == 0) {
        throw StateError('Could not encode the annotated screenshot.');
      }
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } finally {
      composited?.dispose();
      picture?.dispose();
      screenshot.dispose();
    }
  }

  static Future<ui.Image> _captureBoundary(
    RenderRepaintBoundary boundary,
    double pixelRatio,
  ) => boundary.toImage(pixelRatio: pixelRatio);
}
