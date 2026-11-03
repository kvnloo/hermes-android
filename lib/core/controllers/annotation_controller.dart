import 'package:flutter/foundation.dart';

import '../models/annotation_ink.dart';

/// The unfinished stroke is visible immediately, before it is committed.
class LiveInk {
  const LiveInk({
    required this.tool,
    required this.color,
    required this.pointer,
    required this.points,
  });

  final Tool tool;
  final InkColor color;
  final InkPointerKind pointer;
  final List<StrokePoint> points;
}

/// Session-only annotation state. Never reads preferences or restores a mode.
///
/// Closing/reopening is a mode switch, not a discard; only [discard] throws
/// away unsent ink. Matches Dash's annotation store and stylus-mode latch.
class AnnotationController extends ChangeNotifier {
  bool _active = false;
  bool _buttonDown = false;
  bool _penMode = false;
  bool _disposed = false;
  Tool _tool = Tool.pen;
  InkColor _color = InkColor.accent;
  Drawing _drawing = EMPTY_DRAWING;
  LiveInk? _live;

  bool get active => _active;
  bool get buttonDown => _buttonDown;
  bool get penMode => _penMode;
  Tool get tool => _tool;
  InkColor get color => _color;
  Drawing get drawing => _drawing;
  LiveInk? get live => _live;

  void enter() {
    if (_disposed || _active) return;
    _active = true;
    notifyListeners();
  }

  /// A manual mode switch does not change the stylus-button latch.
  void toggle() {
    if (_disposed) return;
    if (_active) _commitLive();
    _active = !_active;
    notifyListeners();
  }

  /// Repeats and releases do not toggle. A press enables palm rejection.
  void stylusButton(bool pressed) {
    if (_disposed || _buttonDown == pressed) return;
    _buttonDown = pressed;
    if (pressed) {
      if (_active) _commitLive();
      _penMode = true;
      _active = !_active;
    }
    notifyListeners();
  }

  void setPenMode(bool value) {
    if (_disposed || _penMode == value) return;
    _commitLive();
    _penMode = value;
    notifyListeners();
  }

  void setTool(Tool value) {
    if (_disposed || _tool == value) return;
    _commitLive();
    _tool = value;
    notifyListeners();
  }

  void setColor(InkColor value) {
    if (_disposed || _color == value) return;
    _commitLive();
    _color = value;
    notifyListeners();
  }

  /// Contact is ignored unless the user explicitly entered annotation mode.
  void startStroke({
    required InkPointerKind pointer,
    required StrokePoint point,
    required int pointers,
  }) {
    if (_disposed ||
        !_active ||
        !routePointer(pointer, penMode: _penMode, pointers: pointers) ||
        !point.x.isFinite ||
        !point.y.isFinite) {
      return;
    }
    _commitLive();
    _live = LiveInk(
      tool: _tool,
      color: _color,
      pointer: pointer,
      points: <StrokePoint>[point],
    );
    notifyListeners();
  }

  void appendStrokePoint(StrokePoint point) {
    final draft = _live;
    if (_disposed ||
        !_active ||
        draft == null ||
        !point.x.isFinite ||
        !point.y.isFinite) {
      return;
    }
    _live = LiveInk(
      tool: draft.tool,
      color: draft.color,
      pointer: draft.pointer,
      points: appendInkSample(draft.points, point),
    );
    notifyListeners();
  }

  /// Erasing is one history entry for the whole drag, not one per sample.
  void finishStroke() {
    if (_disposed || _live == null) return;
    _commitLive();
    notifyListeners();
  }

  /// Multi-pointer gestures cancel only the current preview.
  void cancelStroke() {
    if (_disposed || _live == null) return;
    _live = null;
    notifyListeners();
  }

  bool _commitLive() {
    final draft = _live;
    if (draft == null) return false;
    _live = null;
    final drawTool = drawingTool(draft.tool);
    if (drawTool == null) {
      _drawing = eraseAlong(
        _drawing,
        <InkPosition>[for (final point in draft.points) point],
      );
    } else {
      _drawing = addStroke(
        _drawing,
        tool: drawTool,
        color: draft.color,
        pointer: draft.pointer,
        points: draft.points,
      );
    }
    return true;
  }

  void undoStroke() {
    if (_disposed) return;
    final hadLive = _commitLive();
    final next = undo(_drawing);
    if (identical(next, _drawing) && !hadLive) return;
    _drawing = next;
    notifyListeners();
  }

  void clearStrokes() {
    if (_disposed) return;
    final hadLive = _live != null;
    _live = null;
    final next = clear(_drawing);
    if (identical(next, _drawing) && !hadLive) return;
    _drawing = next;
    notifyListeners();
  }

  /// Explicitly abandon the draft; mode switches never call this.
  void discard() {
    if (_disposed) return;
    if (!_active && _live == null && identical(_drawing, EMPTY_DRAWING)) {
      return;
    }
    _active = false;
    _live = null;
    _drawing = EMPTY_DRAWING;
    // Keep buttonDown until hardware release, so a held press cannot retrigger.
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
