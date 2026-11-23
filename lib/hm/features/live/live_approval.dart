import 'package:flutter/foundation.dart';

import '../../../nextgen/data/chat_controller.dart';

enum LiveRequestAction { allow, deny, open }

/// Match a complete utterance, never a prefix, substring or model paraphrase.
LiveRequestAction? matchLiveRequest(String text) {
  final said = text
      .trim()
      .toLowerCase()
      .replaceFirst(RegExp(r'[.!]+$'), '')
      .replaceAll(RegExp(r'\s+'), ' ');
  return switch (said) {
    'allow' || 'allow once' => LiveRequestAction.allow,
    'deny' => LiveRequestAction.deny,
    'open' || 'open it' => LiveRequestAction.open,
    _ => null,
  };
}

/// Only this call's controller can supply a prompt. NgChatController also
/// checks the gateway's runtime/stored session IDs before exposing requests.
NgInputRequest? liveRequestFor(NgChatController chat) {
  final input = chat.request;
  if (input == null) return null;
  final id = input.request.sessionId;
  if (id == null || (id != chat.runtimeId && id != chat.storedId)) return null;
  return switch (input.kind) {
    NgRequestKind.approval || NgRequestKind.clarify => input,
    NgRequestKind.secret when input.request.method == 'sudo' => input,
    _ => null,
  };
}

class LiveApproval {
  LiveApproval(this.chat, this.openChat);

  final NgChatController chat;
  final VoidCallback openChat;
  NgInputRequest? get pending => liveRequestFor(chat);
  bool returnToChat = false;

  bool act(NgInputRequest input, LiveRequestAction action) {
    if (!identical(pending, input)) return false;
    switch (action) {
      case LiveRequestAction.open:
        return true;
      case LiveRequestAction.allow:
        if (input.kind != NgRequestKind.approval) return false;
        final ok = chat.answerApproval('once');
        if (ok) returnToChat = true;
        return ok;
      case LiveRequestAction.deny:
        return switch (input.kind) {
          NgRequestKind.approval => chat.answerApproval('deny'),
          NgRequestKind.clarify => chat.cancelClarify(),
          NgRequestKind.secret => chat.answerValue(''),
          _ => false,
        };
    }
  }

  String prompt(NgInputRequest input, {bool again = false}) {
    if (input.kind == NgRequestKind.approval) {
      return again
          ? 'Please say allow, deny, or open it.'
          : 'Approval needed. Say allow, deny, or open it.';
    }
    return again
        ? 'Please say open it or deny.'
        : 'Input needed. Say open it or deny.';
  }
}
