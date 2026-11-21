// Artifacts: files and outputs the bot produced.
import 'package:flutter/material.dart';

import '../../../nextgen/data/chat_controller.dart';
import '../../hm_bots.dart';
import '../hm_soon.dart';

/// [chat] is null when opened from Agent settings (all of the bot's artifacts).
Future<void> openHmArtifacts(
  BuildContext context, {
  required HmBot bot,
  required HmBotsModel bots,
  NgChatController? chat,
}) => hmSoon(context, 'Artifacts');
