// Settings: account banner, then agents/instances, device, appearance and
// help groups. Sub-pages not yet rebuilt in the Hermes style open the
// existing NextGen pages (same data, older look).
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/services/connection_manager.dart';
import '../../nextgen/nextgen_preferences.dart';
import '../../nextgen/ui/nextgen_scope.dart';
import '../../nextgen/ui/settings_page.dart';
import '../avatar/hm_avatar.dart';
import '../features/settings/cache_screen.dart';
import '../features/settings/chat_settings_screen.dart';
import '../features/settings/security_screen.dart';
import '../features/settings/settings_prefs.dart';
import '../hm_bots.dart';
import '../hm_ui.dart';
import 'hm_agent_screen.dart';
import 'hm_avatar_picker.dart';

class HmSettingsScreen extends StatelessWidget {
  const HmSettingsScreen({super.key, required this.bots});
  final HmBotsModel bots;

  @override
  Widget build(BuildContext context) {
    final scope = NgScope.of(context);
    final look = NextGenLook.instance;
    final settings = HmSettingsPrefs.instance..ensureLoaded(scope.prefs);
    void push(Widget page) => Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => page));
    return ListenableBuilder(
      listenable: Listenable.merge([bots, look, settings]),
      builder: (context, _) => HmPage(
        title: 'Settings',
        children: [
          HmGroup(
            children: [
              HmRow(
                icon: Icons.group_outlined,
                label: 'Agents',
                value: '${bots.bots.length}',
                onTap: () => push(HmAgentsScreen(bots: bots)),
              ),
              HmRow(
                icon: Icons.dns_outlined,
                label: 'Self-Hosted Instances',
                value: '${scope.connections.length}',
                onTap: () => push(const HmInstancesScreen()),
              ),
            ],
          ),
          const SizedBox(height: HmMetrics.groupGap),
          HmGroup(
            children: [
              HmRow(
                icon: Icons.notifications_none,
                label: 'Notifications',
                onTap: () => push(const NgNotificationSettings()),
              ),
              HmRow(
                icon: Icons.lock_outline,
                label: 'Security',
                value: settings.lockEnabled ? 'On' : 'Off',
                onTap: () => push(const HmSecurityScreen()),
              ),
              HmRow(
                icon: Icons.storage,
                label: 'Caching',
                value: settings.cachingOn ? 'On' : 'Off',
                onTap: () => push(const HmCachingScreen()),
              ),
            ],
          ),
          const SizedBox(height: HmMetrics.groupGap),
          HmGroup(
            children: [
              HmRow(
                icon: Icons.palette_outlined,
                label: 'Look & Feel',
                value: _modeLabel(look.themeMode),
                onTap: () => push(const NgSettingsPage()),
              ),
              HmRow(
                icon: Icons.face_outlined,
                label: 'Bot avatar',
                value: look.avatarStyle.label,
                onTap: () => push(
                  HmAvatarPicker(
                    sample:
                        bots.bots.firstOrNull?.character ??
                        HmCharacterSpec.forName('Hermes'),
                  ),
                ),
              ),
              HmRow(
                icon: Icons.chat_outlined,
                label: 'Chat',
                value: settings.chatStyle.label,
                onTap: () => push(const HmChatSettingsScreen()),
              ),
            ],
          ),
          const SizedBox(height: HmMetrics.groupGap),
          HmGroup(
            children: [
              HmRow(
                icon: Icons.mail_outline,
                label: 'Contact',
                onTap: () => launchUrl(
                  Uri.parse('https://github.com/kvnloo/hermes-android/issues'),
                ),
              ),
              HmRow(
                icon: Icons.menu_book_outlined,
                label: 'Documentation',
                onTap: () => launchUrl(
                  Uri.parse('https://hermes-agent.nousresearch.com/docs'),
                  mode: LaunchMode.inAppBrowserView,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _modeLabel(ThemeMode mode) => switch (mode) {
    ThemeMode.system => 'System',
    ThemeMode.light => 'Light',
    ThemeMode.dark => 'Dark',
  };
}

/// Settings → Agents: every bot on this host.
class HmAgentsScreen extends StatelessWidget {
  const HmAgentsScreen({super.key, required this.bots});
  final HmBotsModel bots;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: bots,
    builder: (context, _) => HmPage(
      title: 'Agents',
      children: [
        HmGroup(
          children: [
            for (final b in bots.bots)
              HmRow(
                label: b.displayName,
                value: b.model.isEmpty ? null : b.model,
                tall: true,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => HmAgentScreen(bot: b, bots: bots),
                  ),
                ),
              ),
          ],
        ),
      ],
    ),
  );
}

/// Settings → Self-Hosted Instances: the saved hosts, which one is in use,
/// and adding another.
class HmInstancesScreen extends StatelessWidget {
  const HmInstancesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = NgScope.of(context);
    final current = scope.connection.id;
    return HmPage(
      title: 'Self-Hosted Instances',
      trailing: [
        HmRoundButton(
          icon: Icons.add,
          label: 'Add Server',
          onPressed: scope.addGateway,
        ),
      ],
      children: [
        HmGroup(
          children: [
            for (final SavedConnection conn in scope.connections)
              HmRow(
                icon: conn.id == current
                    ? Icons.check_circle
                    : Icons.dns_outlined,
                label: conn.label,
                value: Uri.tryParse(conn.singleLoginUrl ?? '')?.host ?? '',
                tall: true,
                onTap: conn.id == current
                    ? null
                    : () async {
                        Navigator.of(context).popUntil((r) => r.isFirst);
                        await scope.switchTo(conn.id);
                      },
              ),
          ],
        ),
      ],
    );
  }
}
