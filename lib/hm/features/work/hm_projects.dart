// Projects: conversations, repositories and worktrees grouped by project.
import 'package:flutter/material.dart';

import '../../hm_bots.dart';
import '../hm_soon.dart';

Future<void> openHmProjects(
  BuildContext context, {
  required HmBot bot,
  required HmBotsModel bots,
}) => hmSoon(context, 'Projects');
