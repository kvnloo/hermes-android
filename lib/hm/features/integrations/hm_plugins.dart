// Plugins: the bot's agent plugins.
import 'package:flutter/material.dart';

import '../../hm_bots.dart';
import '../hm_soon.dart';

Future<void> openHmPlugins(
  BuildContext context, {
  required HmBot bot,
  required HmBotsModel bots,
}) => hmSoon(context, 'Plugins');
