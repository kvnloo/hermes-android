// Placeholder for a feature page that isn't built yet. Each feature lane
// replaces its call; delete this file once nothing calls it.
import 'package:flutter/material.dart';

Future<void> hmSoon(BuildContext context, String what) async {
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text('$what is coming next')));
}
