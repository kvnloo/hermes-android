import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../controllers/annotation_controller.dart';
import '../l10n/l10n.dart';
import 'ink_overlay.dart';

/// The existing draft tiles use two-line ListTiles, which occupy 72 logical
/// pixels at the default text scale.
const double annotationDraftRowExtent = 72;

/// Keeps the composer position fixed while a reserved snapshot becomes a draft.
/// The list scrolls inside its original footprint if more images are captured.
class AnnotationAttachmentSlotViewport extends StatelessWidget {
  const AnnotationAttachmentSlotViewport({
    required this.annotationActive,
    required this.reservedRowCount,
    required this.availableHeight,
    required this.child,
    super.key,
  });

  final bool annotationActive;
  final int reservedRowCount;
  final double availableHeight;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final limit = availableHeight * 0.32;
    final fixedHeight = (reservedRowCount * annotationDraftRowExtent)
        .clamp(0.0, limit)
        .toDouble();
    return ConstrainedBox(
      constraints: BoxConstraints(
        minHeight: annotationActive ? fixedHeight : 0,
        maxHeight: annotationActive ? fixedHeight : limit,
      ),
      child: child,
    );
  }
}

/// A chat-only drawing layer; the RepaintBoundary is strictly below the ink.
/// It never changes the chat/composer geometry while a capture is in flight.
class AnnotationChatShell extends StatelessWidget {
  const AnnotationChatShell({
    required this.controller,
    required this.boundaryKey,
    required this.onCapture,
    required this.capturing,
    required this.child,
    super.key,
  });

  /// The chat/voice route owns this controller. Null means no annotation owner.
  final AnnotationController? controller;
  final GlobalKey boundaryKey;
  final VoidCallback onCapture;
  final bool capturing;
  final Widget child;

  void _observeStylus(PointerEvent event) {
    if (event.kind != PointerDeviceKind.stylus) return;
    final pressed =
        (event.buttons & (kPrimaryStylusButton | kSecondaryStylusButton)) != 0;
    controller?.stylusButton(pressed);
  }

  void _releaseStylus(PointerEvent event) {
    if (event.kind == PointerDeviceKind.stylus) {
      controller?.stylusButton(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ink = controller;
    if (ink == null) return child;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerHover: _observeStylus,
      onPointerDown: _observeStylus,
      onPointerMove: _observeStylus,
      onPointerUp: _releaseStylus,
      onPointerCancel: _releaseStylus,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          RepaintBoundary(key: boundaryKey, child: child),
          AnimatedBuilder(
            animation: ink,
            builder: (context, _) {
              if (!ink.active) return const SizedBox.shrink();
              final colors = Theme.of(context).colorScheme;
              final l10n = context.l10n;
              return Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  Positioned.fill(child: InkOverlay(controller: ink)),
                  Positioned(
                    top: 8,
                    right: 8,
                    child: Material(
                      elevation: 2,
                      color: colors.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(16),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          IconButton(
                            key: const Key('annotation-undo'),
                            tooltip: l10n.annotation_undo,
                            onPressed: ink.drawing.past.isEmpty &&
                                    ink.live == null
                                ? null
                                : ink.undoStroke,
                            icon: const Icon(Icons.undo),
                          ),
                          IconButton(
                            key: const Key('annotation-clear'),
                            tooltip: l10n.annotation_clear,
                            onPressed: ink.drawing.strokes.isEmpty &&
                                    ink.live == null
                                ? null
                                : ink.clearStrokes,
                            icon: const Icon(Icons.layers_clear_outlined),
                          ),
                          IconButton(
                            key: const Key('annotation-snapshot'),
                            tooltip: l10n.annotation_snapshot,
                            onPressed: capturing ? null : onCapture,
                            icon: capturing
                                ? const SizedBox.square(
                                    dimension: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.add_photo_alternate_outlined),
                          ),
                          IconButton(
                            key: const Key('annotation-exit'),
                            tooltip: l10n.annotation_exit,
                            onPressed: capturing ? null : ink.toggle,
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
