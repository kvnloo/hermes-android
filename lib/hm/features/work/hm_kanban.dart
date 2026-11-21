// Kanban: the bot's boards and tasks.
import 'package:flutter/material.dart';

import '../../hm_bots.dart';
import '../hm_soon.dart';

Future<void> openHmKanban(
  BuildContext context, {
  required HmBot bot,
  required HmBotsModel bots,
}) => hmSoon(context, 'Kanban');
