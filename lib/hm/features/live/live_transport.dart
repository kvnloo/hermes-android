// The four seams a live call talks through, and their production adapters.
//
// Transport: Hermes's chained voice loop (voice.voice_chat_mode: chained,
// the host default; tools/voice_live.py). The ear is on-device speech
// recognition, each heard utterance is a normal turn on the bot's chat
// (prompt.submit through NgChatController), and the reply is spoken with
// the host's TTS (POST /api/audio/speak), else the device's.
// When the host selects GPT-Live (voice_chat_mode: gpt-live) and can start
// it, the call runs over WebRTC instead (live_webrtc.dart), and this loop is
// the fallback.
import 'dart:async';
import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../../core/services/connection_manager.dart';
import '../../../core/services/dashboard_api_client.dart';
import '../../../core/services/voice_composer_adapter.dart';
import '../../../core/widgets/ephemeral_ui_card.dart';
import '../../../nextgen/data/chat_controller.dart';
import '../../../nextgen/data/read_aloud.dart';
import 'live_strings.dart';
import 'live_webrtc.dart';

// ── Data shapes ─────────────────────────────────────────────────────────────

/// `GET /api/audio/voice-live/status`: which voice engine the profile picked.
@immutable
class LiveVoiceStatus {
  const LiveVoiceStatus({
    required this.mode,
    required this.gptLiveAvailable,
    this.reason,
    this.model,
    this.voice,
  });

  /// `chained` or `gpt-live`.
  final String mode;
  final bool gptLiveAvailable;
  final String? reason;
  final String? model;
  final String? voice;

  /// The profile selected GPT-Live (Desktop and the official app follow
  /// this host setting).
  bool get gptLiveSelected => mode == 'gpt-live';

  /// Selected and startable: the call goes over WebRTC.
  bool get useWebRtc => gptLiveSelected && gptLiveAvailable;

  factory LiveVoiceStatus.fromJson(Map<String, dynamic> j) {
    final raw = (j['mode'] ?? 'chained').toString().trim().toLowerCase();
    return LiveVoiceStatus(
      mode: raw.replaceAll('_', '-') == 'gpt-live' ? 'gpt-live' : 'chained',
      gptLiveAvailable: j['available'] == true,
      reason: j['reason']?.toString(),
      model: j['model']?.toString(),
      voice: j['voice']?.toString(),
    );
  }
}

/// `POST /api/audio/speak`: one synthesized reply.
@immutable
class LiveSpeech {
  const LiveSpeech(this.bytes, this.mimeType);
  final Uint8List bytes;
  final String mimeType;

  /// Parses `{data_url: "data:<mime>;base64,<audio>", mime_type}`.
  static LiveSpeech? fromJson(Map<String, dynamic> j) {
    final url = j['data_url'];
    if (url is! String) return null;
    final comma = url.indexOf(',');
    if (!url.startsWith('data:') || comma < 0) return null;
    final header = url.substring(5, comma);
    final mime = (j['mime_type'] as String?) ?? header.split(';').first;
    try {
      return LiveSpeech(base64Decode(url.substring(comma + 1)), mime);
    } on FormatException {
      return null;
    }
  }
}

/// One line of the call's transcript, read from the chat.
@immutable
class LiveLine {
  const LiveLine({
    required this.key,
    required this.fromUser,
    required this.text,
    this.tools = const [],
    this.cards = const [],
    this.work = false,
  });
  final String key;
  final bool fromUser;
  final String text;

  /// The agent's tool calls in this reply, as the chat holds them (live
  /// objects: running, then done with a result).
  final List<NgTool> tools;

  /// The sources of the ephemeral-ui cards in this reply, drawn with the
  /// chat's renderer.
  final List<String> cards;

  /// The agent's work on a delegated request (its tool rows), not speech.
  final bool work;
}

/// The host has no voice routes (older Hermes): 404 on `/api/audio/*`.
class LiveNoVoiceApi implements Exception {
  const LiveNoVoiceApi();
}

/// A turn that could not be sent or failed on the host.
class LiveTurnFailed implements Exception {
  const LiveTurnFailed(this.message);
  final String message;
  @override
  String toString() => message;
}

enum LiveMicAccess { granted, denied, unavailable }

// ── Seams ───────────────────────────────────────────────────────────────────

/// The host's voice routes.
abstract interface class LiveHost {
  Future<LiveVoiceStatus> status();
  Future<LiveSpeech> speak(String text);

  /// Exchanges a WebRTC SDP offer for the GPT-Live answer.
  Future<LiveSessionAnswer> createSession(
    String sdp, {
    List<Map<String, Object?>> history,
  });
}

/// The microphone and speech recognizer: one utterance per [listen].
abstract interface class LiveEar {
  Future<LiveMicAccess> open();

  /// Hears one utterance. Exactly one of [onFinal] / [onError] ends it;
  /// [onFinal] may carry empty text when nothing was said.
  Future<void> listen({
    required void Function(String text) onPartial,
    required void Function(String text) onFinal,
    required void Function(String message) onError,
  });

  Future<void> stop();
  void dispose();
}

/// The bot: sends a heard utterance as a turn and returns the reply text.
abstract interface class LiveBrain implements Listenable {
  /// This call's turns, as the chat holds them.
  List<LiveLine> get lines;
  Future<String> ask(String text);

  /// The tool the running turn is on ("terminal · git status"), else null.
  String? get activeTool;
  void dispose();
}

/// The speaker. [speak] completes when the reply ends or is stopped.
abstract interface class LiveVoice {
  /// Set once the host turned out to have no TTS route.
  bool get onDevice;
  Future<void> speak(String text);
  Future<void> stop();
  void dispose();
}

// ── Production adapters ─────────────────────────────────────────────────────

/// [LiveHost] over the signed-in dashboard, scoped to one bot's profile.
class DashboardLiveHost implements LiveHost {
  DashboardLiveHost(this.dashboard, {this.profile});
  final DashboardClient dashboard;
  final String? profile;

  Map<String, String>? get _query =>
      profile == null ? null : {'profile': profile!};

  Map<String, dynamic> _ok(http.Response res) {
    if (res.statusCode == 404) throw const LiveNoVoiceApi();
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw DashboardRequestException(
        res.statusCode,
        dashboardErrorMessage(res),
      );
    }
    final decoded = jsonDecode(res.body);
    return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
  }

  @override
  Future<LiveVoiceStatus> status() async => LiveVoiceStatus.fromJson(
    _ok(
      await dashboard.apiRequest(
        'GET',
        'audio/voice-live/status',
        queryParameters: _query,
      ),
    ),
  );

  @override
  Future<LiveSessionAnswer> createSession(
    String sdp, {
    List<Map<String, Object?>> history = const [],
  }) async {
    final res = await dashboard.apiRequest(
      'POST',
      'audio/voice-live/session',
      // The provider's SDP parser needs the offer byte-exact.
      body: {'sdp': sdp, if (history.isNotEmpty) 'history': history},
      queryParameters: _query,
      // The host waits on the provider (30 s there); Desktop allows 45 s.
      timeout: const Duration(seconds: 45),
    );
    if (res.statusCode == 404) {
      throw const LiveCallSetupFailed(LiveText.gptLiveCouldNotConnect);
    }
    // 503: the host has no key for GPT-Live.
    if (res.statusCode == 503) {
      throw const LiveCallSetupFailed(LiveText.gptLiveNotConfigured);
    }
    return LiveSessionAnswer.fromJson(_ok(res));
  }

  @override
  Future<LiveSpeech> speak(String text) async {
    final speech = LiveSpeech.fromJson(
      _ok(
        await dashboard.apiRequest(
          'POST',
          'audio/speak',
          body: {'text': text},
          queryParameters: _query,
          // Synthesis blocks until the provider finishes; long replies take
          // well past the default timeout (desktop scales it the same way).
          timeout: Duration(seconds: 30 + text.length ~/ 40),
        ),
      ),
    );
    if (speech == null) {
      throw const DashboardRequestException(500, 'Invalid TTS response');
    }
    return speech;
  }
}

/// [LiveEar] over the same recognizer the composer dictates with.
class DeviceLiveEar implements LiveEar {
  DeviceLiveEar(this.adapter);
  final VoiceComposerAdapter adapter;

  int _utterance = 0;
  String _last = '';
  void Function(String)? _onFinal;
  void Function(String)? _onError;

  void _finish(int id, {String? error}) {
    if (id != _utterance) return;
    _utterance++;
    final done = error == null ? _onFinal : null;
    final failed = error != null ? _onError : null;
    _onFinal = null;
    _onError = null;
    if (done != null) done(_last.trim());
    if (failed != null) failed(error!);
  }

  @override
  Future<LiveMicAccess> open() async {
    final ok = await adapter.initialize(
      onStatus: (status) {
        if (status == 'done' || status == 'notListening') _finish(_utterance);
      },
      onError: (message) => _finish(_utterance, error: message),
    );
    if (ok) return LiveMicAccess.granted;
    return await adapter.hasPermission
        ? LiveMicAccess.unavailable
        : LiveMicAccess.denied;
  }

  @override
  Future<void> listen({
    required void Function(String text) onPartial,
    required void Function(String text) onFinal,
    required void Function(String message) onError,
  }) async {
    final id = _utterance;
    _last = '';
    _onFinal = onFinal;
    _onError = onError;
    try {
      await adapter.listen(
        onResult: ({required transcript, required isFinal}) {
          if (id != _utterance) return;
          _last = transcript;
          if (isFinal) {
            _finish(id);
          } else {
            onPartial(transcript);
          }
        },
      );
    } catch (e) {
      _finish(id, error: '$e');
    }
  }

  @override
  Future<void> stop() async {
    _utterance++;
    _onFinal = null;
    _onError = null;
    try {
      await adapter.cancel();
    } catch (_) {
      // Already stopped.
    }
  }

  @override
  void dispose() {
    _utterance++;
    adapter.dispose();
  }
}

/// [LiveBrain] over the bot's open chat: every turn lands in that chat.
class ChatLiveBrain extends ChangeNotifier implements LiveBrain {
  ChatLiveBrain(this.chat) : _from = chat.items.length {
    chat.addListener(notifyListeners);
  }

  final NgChatController chat;

  /// Only this call's turns show in the call's transcript.
  final int _from;

  @override
  List<LiveLine> get lines => [
    for (final item in chat.items.skip(_from))
      if (item is NgUserItem && item.text.trim().isNotEmpty)
        LiveLine(key: item.key, fromUser: true, text: item.text.trim())
      else if (item is NgAssistantItem &&
          (item.text.trim().isNotEmpty || item.tools.isNotEmpty))
        LiveLine(
          key: item.key,
          fromUser: false,
          text: item.text.trim(),
          tools: List.of(item.tools),
          cards: ephemeralUiFences(item.text),
        ),
  ];

  @override
  String? get activeTool {
    final items = chat.items;
    for (var i = items.length - 1; i >= _from && i >= 0; i--) {
      final item = items[i];
      if (item is! NgAssistantItem) continue;
      final tool = item.tools.where((t) => t.running).lastOrNull;
      if (tool == null) return null;
      final detail = tool.detail?.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (detail == null || detail.isEmpty) return tool.name;
      return '${tool.name} · ${detail.length > 80 ? '${detail.substring(0, 80)}…' : detail}';
    }
    return null;
  }

  @override
  Future<String> ask(String text) async {
    final before = chat.items.length;
    final sent = await chat.send(text);
    if (!sent) {
      final failed = chat.items
          .skip(before)
          .whereType<NgUserItem>()
          .lastOrNull
          ?.failure;
      throw LiveTurnFailed(failed ?? chat.error ?? 'Not delivered.');
    }
    if (chat.running) {
      final done = Completer<void>();
      void check() {
        if (!chat.running && !done.isCompleted) done.complete();
      }

      chat.addListener(check);
      try {
        await done.future;
      } finally {
        chat.removeListener(check);
      }
    }
    final error = chat.error;
    final reply = chat.items
        .skip(before)
        .whereType<NgAssistantItem>()
        .lastOrNull
        ?.text
        .trim();
    if ((reply == null || reply.isEmpty) && error != null) {
      throw LiveTurnFailed(error);
    }
    return reply ?? '';
  }

  @override
  void dispose() {
    chat.removeListener(notifyListeners);
    super.dispose();
  }
}

/// [LiveVoice]: the host's TTS, else the device's when the host has none.
class HostLiveVoice implements LiveVoice {
  HostLiveVoice(this.host, {AudioPlayer? player, NgReadAloud? device})
    : _player = player ?? AudioPlayer(),
      _device = device ?? NgReadAloud();

  final LiveHost host;
  final AudioPlayer _player;
  final NgReadAloud _device;
  bool _onDevice = false;
  int _gen = 0;
  Completer<void>? _playing;

  @override
  bool get onDevice => _onDevice;

  @override
  Future<void> speak(String text) async {
    final gen = ++_gen;
    if (!_onDevice) {
      try {
        final speech = await host.speak(text);
        if (gen != _gen) return;
        await _play(speech);
        return;
      } on LiveNoVoiceApi {
        _onDevice = true;
      } catch (_) {
        // This reply only: fall back to the device's voice.
      }
      if (gen != _gen) return;
    }
    await _speakOnDevice(text, gen);
  }

  Future<void> _play(LiveSpeech speech) async {
    final done = _playing = Completer<void>();
    final sub = _player.onPlayerComplete.listen((_) {
      if (!done.isCompleted) done.complete();
    });
    try {
      await _player.play(BytesSource(speech.bytes, mimeType: speech.mimeType));
      await done.future;
    } finally {
      await sub.cancel();
      if (identical(_playing, done)) _playing = null;
    }
  }

  Future<void> _speakOnDevice(String text, int gen) async {
    const key = 'live';
    await _device.read(key, text);
    // Off Android the engine reports the end on a side channel.
    while (gen == _gen && _device.isReading(key)) {
      final changed = Completer<void>();
      void ping() {
        if (!changed.isCompleted) changed.complete();
      }

      _device.addListener(ping);
      try {
        await changed.future;
      } finally {
        _device.removeListener(ping);
      }
    }
  }

  @override
  Future<void> stop() async {
    _gen++;
    final playing = _playing;
    if (playing != null && !playing.isCompleted) playing.complete();
    try {
      await _player.stop();
    } catch (_) {}
    await _device.stop();
  }

  @override
  void dispose() {
    _gen++;
    unawaited(_player.dispose().catchError((Object _) {}));
    _device.dispose();
  }
}

/// The notice the call shows once the reply voice moved on-device.
String? liveVoiceNotice(LiveVoice voice) =>
    voice.onDevice ? LiveText.speechOnDevice : null;
