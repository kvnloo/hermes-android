// Execution: goals, tasks, subagents and terminal processes of this chat.
import 'package:flutter/material.dart';

import '../../../nextgen/data/chat_controller.dart';
import '../../hm_bots.dart';
import '../hm_soon.dart';

Future<void> openHmExecution(
  BuildContext context, {
  required HmBot bot,
  required HmBotsModel bots,
  required NgChatController chat,
}) => hmSoon(context, 'Execution');
