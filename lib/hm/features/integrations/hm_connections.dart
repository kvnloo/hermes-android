// Connections: messaging platforms and accounts the bot can use.
import 'package:flutter/material.dart';

import '../../hm_bots.dart';
import '../hm_soon.dart';

Future<void> openHmConnections(
  BuildContext context, {
  required HmBot bot,
  required HmBotsModel bots,
}) => hmSoon(context, 'Connections');
