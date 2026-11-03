import 'dart:async';

import 'package:flutter/material.dart';

import '../annotation/annotation_compose.dart';
import '../annotation/annotation_voice_segments.dart';
import '../annotation/annotation_voice_send.dart';
import '../controllers/voice_composer_controller.dart';
import '../services/android_voice_composer_adapter.dart';
import '../services/voice_composer_adapter.dart';
import 'package:hermes_android/core/l10n/l10n.dart';

/// The voice/send portion of the annotation tray. The separate ink and
/// screenshot owners supply live strokes and attach the image/JSON through the
/// sender's existing gateway port; this widget never fabricates a drawing.
class AnnotationVoiceTray extends StatefulWidget {
  const AnnotationVoiceTray({
    required this.conversationId,
    required this.screen,
    required this.currentStrokes,
    required this.sender,
    required this.beforeRecording,
    required this.onConfirmed,
    required this.handsFreeSpeechEnabled,
    required this.speakReply,
    this.onFinalTurn,
    this.voiceAdapter,
    this.localeId,
    this.clock,
    super.key,
  });

  final String conversationId;
  final ScreenInfo screen;
  final List<Stroke> Function() currentStrokes;
  final AnnotationVoiceSendController sender;
  final Future<void> Function() beforeRecording;
  final Future<void> Function(
    AnnotationSendEnvelope submitted,
    AnnotationSendOutcome receipt,
  ) onConfirmed;
  final bool Function() handsFreeSpeechEnabled;
  final Future<void> Function(String reply) speakReply;

  /// A confirmed receipt can precede the final answer. The owning chat
  /// observes that exact turn ID to speak its later final once, if enabled.
  final void Function(String turnId)? onFinalTurn;
  final VoiceComposerAdapter? voiceAdapter;
  final String? localeId;
  final int Function()? clock;

  @override
  State<AnnotationVoiceTray> createState() => _AnnotationVoiceTrayState();
}

class _AnnotationVoiceTrayState extends State<AnnotationVoiceTray> {
  late final TextEditingController _dictated;
  late final TextEditingController _typed;
  late final VoiceComposerController _composer;
  late final AnnotationVoiceSegments _voice;
  bool _pressed = false;
  bool _sending = false;
  bool _releasing = false;
  Future<void>? _starting;
  int _hold = 0;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _dictated = TextEditingController();
    _typed = TextEditingController();
    _composer = VoiceComposerController(
      textController: _dictated,
      adapter: widget.voiceAdapter ?? createVoiceComposerAdapter(),
    )..addListener(_rebuild);
    _voice = AnnotationVoiceSegments(
      composer: _composer,
      clock: widget.clock,
    );
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  void _startHolding() {
    if (_pressed || _sending || _releasing) return;
    _pressed = true;
    final intent = ++_hold;
    _starting = _begin(intent);
  }

  Future<void> _begin(int intent) async {
    try {
      await widget.beforeRecording();
      if (!mounted || !_pressed || intent != _hold) return;
      final started = await _voice.begin(localeId: widget.localeId);
      if (!mounted || intent != _hold) return;
      if (!started) {
        setState(
          () => _notice = _composer.status ??
              context.l10n.speech_recognition_is_unavailable,
        );
      }
    } catch (error) {
      if (mounted && intent == _hold) {
        setState(() => _notice = error.toString());
      }
    }
  }

  void _stopHolding({bool discard = false}) {
    if (!_pressed) return;
    _pressed = false;
    unawaited(_release(discard: discard));
  }

  Future<void> _release({required bool discard}) async {
    if (_releasing) return;
    _releasing = true;
    try {
      await _starting;
      if (discard) {
        await _voice.cancel();
      } else {
        await _voice.end();
      }
    } catch (error) {
      if (mounted) setState(() => _notice = error.toString());
    } finally {
      _releasing = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _send() async {
    if (_sending || _releasing) return;
    setState(() {
      _sending = true;
      _notice = null;
    });
    try {
      if (_pressed) _stopHolding();
      await _starting;
      if (_voice.recording) await _voice.end();
      final envelope = AnnotationSendEnvelope(
        conversationId: widget.conversationId,
        strokes: List<Stroke>.unmodifiable(widget.currentStrokes()),
        segments: _voice.segments,
        screen: widget.screen,
        createdAt: (widget.clock ?? (() => DateTime.now().millisecondsSinceEpoch))(),
        typed: _typed.text,
      );
      final result = await widget.sender.send(envelope);
      if (!mounted) return;
      if (!result.confirmed) {
        setState(
          () => _notice =
              context.l10n.delivery_is_uncertain_recovering_without_resending,
        );
        return;
      }
      // First remove exactly the captured drawing/speech. Only then can the
      // receipt be cleared; new ink recorded during upload must survive.
      await widget.onConfirmed(envelope, result);
      _voice.removeSubmitted(envelope.segments);
      await widget.sender.drawingCleared(result.turn);
      if (!mounted) return;
      _typed.clear();
      setState(() => _notice = null);
      if (result.receipt.kind == AnnotationReceiptKind.finalReply) {
        final reply = result.receipt.reply?.trim() ?? '';
        if (reply.isNotEmpty && widget.handsFreeSpeechEnabled()) {
          await widget.speakReply(reply);
        }
      } else {
        widget.onFinalTurn?.call(result.turn.turnId);
      }
    } catch (error) {
      if (mounted) setState(() => _notice = error.toString());
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  void dispose() {
    _pressed = false;
    ++_hold;
    _composer
      ..removeListener(_rebuild)
      ..dispose();
    _dictated.dispose();
    _typed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final transcript = _voice.alignedWith(widget.currentStrokes()).text;
    final listening = _voice.recording;
    return Material(
      color: scheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (transcript.isNotEmpty)
                SelectableText(
                  transcript,
                  key: const Key('annotation-aligned-transcript'),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              TextField(
                key: const Key('annotation-typed-note'),
                controller: _typed,
                minLines: 1,
                maxLines: 3,
                enabled: !_sending,
                decoration: InputDecoration(
                  labelText: context.l10n.message,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      key: const Key('annotation-hold-to-talk'),
                      onLongPressStart: (_) => _startHolding(),
                      onLongPressEnd: (_) => _stopHolding(),
                      onLongPressCancel: () => _stopHolding(discard: true),
                      child: Semantics(
                        button: true,
                        label: listening
                            ? context.l10n.stop_voice_input
                            : context.l10n.start_voice_input,
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: listening
                                ? scheme.errorContainer
                                : scheme.secondaryContainer,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.mic,
                                color: listening
                                    ? scheme.onErrorContainer
                                    : scheme.onSecondaryContainer,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                listening
                                    ? context.l10n.stop_voice_input
                                    : context.l10n.start_voice_input,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    key: const Key('annotation-voice-send'),
                    onPressed: _sending || _releasing || listening ? null : _send,
                    icon: const Icon(Icons.send),
                    label: Text(context.l10n.send),
                  ),
                ],
              ),
              if (_sending) const LinearProgressIndicator(),
              if (_notice != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _notice!,
                    key: const Key('annotation-send-status'),
                    style: TextStyle(color: scheme.error),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
