// The numbers Agent settings prints beside Plugins and MCP: how many plugins
// the bot's profile has installed and how many MCP servers it configures.
import 'package:flutter/foundation.dart';

import 'integrations_api.dart';

/// One row's count. Loading and failure both show no number.
@immutable
sealed class HmCount {
  const HmCount();

  /// The text beside the row, or null for none. A zero shows none too: the
  /// official Agent settings leaves a row blank rather than printing "0".
  String? get label => switch (this) {
    HmCountLoaded(:final n) when n > 0 => '$n',
    _ => null,
  };
}

final class HmCountLoading extends HmCount {
  const HmCountLoading();
}

final class HmCountFailed extends HmCount {
  const HmCountFailed();
}

final class HmCountLoaded extends HmCount {
  const HmCountLoaded(this.n);
  final int n;
}

/// Installed plugins: every row `GET /api/dashboard/plugins/hub` lists for
/// the profile (bundled and user-installed alike), as the official count.
Future<HmCount> hmPluginCount(HmIntegrationsApi api) async {
  try {
    return HmCountLoaded((await api.loadPlugins()).length);
  } catch (_) {
    return const HmCountFailed();
  }
}

/// Configured MCP servers from `GET /api/mcp/servers` for the profile.
Future<HmCount> hmMcpCount(HmIntegrationsApi api) async {
  try {
    return HmCountLoaded((await api.loadMcpServers()).length);
  } catch (_) {
    return const HmCountFailed();
  }
}
