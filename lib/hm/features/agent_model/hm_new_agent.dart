// New Agent: create a bot (a host profile).
import 'package:flutter/material.dart';

import '../../hm_bots.dart';
import '../hm_soon.dart';

Future<void> openHmNewAgent(
  BuildContext context, {
  required HmBotsModel bots,
}) => hmSoon(context, 'New Agent');
