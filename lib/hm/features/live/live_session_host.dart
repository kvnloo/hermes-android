import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../hm_bots.dart';
import 'live_controller.dart';
import 'live_approval.dart';
import '../../../nextgen/data/chat_controller.dart';

abstract interface class LiveBackground {
  Future<bool> start(int session);
  Future<void> stop(int session);
  void listen(void Function(String action, int session)? listener);
}

class AndroidLiveBackground implements LiveBackground {
  static AndroidLiveBackground? _listenerOwner;
  static const _channel = MethodChannel('hermes/live_session');

  @override
  Future<bool> start(int session) async {
    try {
      return await _channel.invokeMethod<bool>('start', session) == true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<void> stop(int session) async {
    try {
      await _channel.invokeMethod<void>('stop', session);
    } on PlatformException {
      // Native task removal also stops the service.
    } on MissingPluginException {
      // There is no service on this platform.
    }
  }

  @override
  void listen(void Function(String action, int session)? listener) {
    if (listener == null) {
      if (identical(_listenerOwner, this)) {
        _listenerOwner = null;
        _channel.setMethodCallHandler(null);
      }
      return;
    }
    _listenerOwner = this;
    _channel.setMethodCallHandler((call) async {
      final id = call.arguments;
      if (id is int) listener(call.method, id);
    });
  }
}

/// The navigator's call owner. No route owns the microphone or the chat lease.
class LiveSessionHost extends ChangeNotifier with WidgetsBindingObserver {
  LiveSessionHost({required this.background, required this.backgroundAllowed}) {
    WidgetsBinding.instance.addObserver(this);
    backgroundAllowed.addListener(_policyChanged);
    background.listen(_action);
  }

  final LiveBackground background;
  final ValueNotifier<bool> backgroundAllowed;
  HmBot? bot;
  LiveController? live;
  VoidCallback? onReturn;
  Future<void> Function()? onRetry;
  LiveApproval? approval;
  VoidCallback? onOpenRequest;

  void bindChat(NgChatController chat, VoidCallback openChat) {
    approval = LiveApproval(chat, openChat);
  }

  bool act(NgInputRequest input, LiveRequestAction action) {
    final ok = approval?.act(input, action) ?? false;
    if (ok && action == LiveRequestAction.open) {
      onOpenRequest?.call();
    }
    if (ok && !_disposed) notifyListeners();
    return ok;
  }

  VoidCallback? takeApprovedDestination() {
    final current = approval;
    if (current == null || !current.returnToChat) return null;
    current.returnToChat = false;
    return current.openChat;
  }

  static int _nextSession = DateTime.now().millisecondsSinceEpoch;
  int _session = 0;
  int _protectionGeneration = 0;
  bool _protected = false;
  bool _startingService = false;
  bool _attempted = false;
  bool _backgrounded = false;
  bool _disposed = false;
  Future<void>? _ending;
  final _seenCards = <(String, String)>{};
  bool newCard = false;
  bool fullScreen = false;
  bool choosingBot = false;
  bool requestDialogOpen = false;
  Route<void>? fullRoute;

  bool get active => live?.isOver == false;
  bool get showPill => active || live?.phase == LivePhase.failed;

  Future<void> begin(HmBot target, LiveController Function() create) async {
    await end();
    if (_disposed || live != null) return;
    bot = target;
    _session = ++_nextSession;
    _attempted = false;
    _seenCards.clear();
    newCard = false;
    final controller = live = create();
    controller.addListener(_changed);
    unawaited(controller.start());
    _changed();
  }

  void setFullScreen(bool visible) {
    if (_disposed || fullScreen == visible) return;
    fullScreen = visible;
    if (visible) newCard = false;
    notifyListeners();
  }

  void _changed() {
    if (_disposed) return;
    final controller = live;
    if (controller == null) return;
    for (final line in controller.lines) {
      for (final card in line.cards) {
        if (_seenCards.add((line.key, card)) && !fullScreen) newCard = true;
      }
    }
    if (controller.isOver) {
      if (_protected || _startingService) unawaited(background.stop(_session));
      _protected = false;
    } else {
      _tryProtection();
    }
    notifyListeners();
  }

  void _tryProtection() {
    if (!backgroundAllowed.value ||
        _backgrounded ||
        _attempted ||
        live?.microphoneReady != true) {
      return;
    }
    _attempted = true;
    _startingService = true;
    final id = _session;
    final generation = ++_protectionGeneration;
    unawaited(
      background.start(id).then((ok) {
        if (_disposed ||
            id != _session ||
            !active ||
            !backgroundAllowed.value) {
          if (ok) unawaited(background.stop(id));
          return;
        }
        if (generation != _protectionGeneration) return;
        _startingService = false;
        _protected = ok;
        if (_backgrounded && !ok) live?.pause();
      }),
    );
  }

  void _policyChanged() {
    if (!backgroundAllowed.value) {
      _protectionGeneration++;
      _protected = false;
      _startingService = false;
      unawaited(background.stop(_session));
      if (_backgrounded) live?.pause();
    } else {
      _attempted = false;
      _tryProtection();
    }
  }

  void _action(String action, int id) {
    if (id != _session || !active) return;
    switch (action) {
      case 'return':
        onReturn?.call();
      case 'mute':
        live?.toggleMute();
      case 'end':
        takeApprovedDestination()?.call();
        unawaited(end());
      case 'unavailable':
        _protected = false;
        if (_backgrounded) live?.pause();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.detached:
        unawaited(end());
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        _backgrounded = true;
        if (!_protected && !_startingService) live?.pause();
      case AppLifecycleState.resumed:
        _backgrounded = false;
        if (!_protected && !_startingService) _attempted = false;
        live?.resume();
        _tryProtection();
      case AppLifecycleState.inactive:
        break;
    }
  }

  Future<void> end() {
    final ending = _ending;
    if (ending != null) return ending;
    final controller = live;
    if (controller == null) return Future.value();
    controller.removeListener(_changed);
    live = null;
    bot = null;
    onReturn = null;
    onRetry = null;
    onOpenRequest = null;
    approval = null;
    _protected = _startingService = false;
    final work =
        Future.wait<void>([
          background.stop(_session),
          controller.end(),
        ]).whenComplete(() {
          // A popped route can still be animating with this controller.
          controller.dispose();
          _ending = null;
        });
    _ending = work.then((_) {});
    if (!_disposed) notifyListeners();
    return _ending!;
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    backgroundAllowed.removeListener(_policyChanged);
    background.listen(null);
    unawaited(end());
    super.dispose();
  }
}
