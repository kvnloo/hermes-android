// Terminal: a shell on the host, in this chat's working directory.
import 'package:flutter/material.dart';

import '../../../nextgen/data/chat_controller.dart';
import '../../hm_bots.dart';
import '../hm_soon.dart';

Future<void> openHmTerminal(
  BuildContext context, {
  required HmBot bot,
  required HmBotsModel bots,
  required NgChatController chat,
}) => hmSoon(context, 'Terminal');
