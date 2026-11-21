// Live Mode: a full-screen voice call with the bot.
import 'package:flutter/material.dart';

import '../../../nextgen/data/chat_controller.dart';
import '../../hm_bots.dart';
import '../hm_soon.dart';

Future<void> openHmLive(
  BuildContext context, {
  required HmBot bot,
  required HmBotsModel bots,
  required NgChatController chat,
}) => hmSoon(context, 'Live Mode');
