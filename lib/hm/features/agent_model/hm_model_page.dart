// Model: what the bot runs on.
import 'package:flutter/material.dart';

import '../../hm_bots.dart';
import '../hm_soon.dart';

Future<void> openHmModelPage(
  BuildContext context, {
  required HmBot bot,
  required HmBotsModel bots,
}) => hmSoon(context, 'Model');
