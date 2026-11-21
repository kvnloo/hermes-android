// Agent settings: the bot's character and name, what it runs on, its
// integrations and its work.
import 'package:flutter/material.dart';

import '../../nextgen/theme/nextgen_theme.dart';
import '../../nextgen/ui/capabilities_page.dart';
import '../../nextgen/ui/scheduled_page.dart';
import '../features/agent_model/hm_model_page.dart';
import '../features/agent_model/hm_new_agent.dart';
import '../features/artifacts/hm_artifacts.dart';
import '../features/integrations/hm_connections.dart';
import '../features/integrations/hm_mcp.dart';
import '../features/integrations/hm_plugins.dart';
import '../features/integrations/integration_counts.dart';
import '../features/integrations/integrations_api.dart';
import '../features/integrations/integrations_kit.dart';
import '../features/work/hm_kanban.dart';
import '../features/work/hm_projects.dart';
import '../hm_bots.dart';
import '../avatar/hm_avatar.dart';
import '../hm_ui.dart';

class HmAgentScreen extends StatefulWidget {
  const HmAgentScreen({
    super.key,
    required this.bot,
    required this.bots,
    this.integrations,
  });

  /// The bot as it was when opened; the screen shows [bots]'s newest copy.
  final HmBot bot;
  final HmBotsModel bots;

  /// Test hook: the scoped integrations client behind the row counts.
  @visibleForTesting
  final HmIntegrationsApi? integrations;

  @override
  State<HmAgentScreen> createState() => _HmAgentScreenState();
}

class _HmAgentScreenState extends State<HmAgentScreen> {
  HmCount _plugins = const HmCountLoading();
  HmCount _mcp = const HmCountLoading();
  late final HmIntegrationsApi _api =
      widget.integrations ?? hmIntegrationsFor(widget.bot, widget.bots);

  HmBot get bot => widget.bot;
  HmBotsModel get bots => widget.bots;

  @override
  void initState() {
    super.initState();
    _loadPlugins();
    _loadMcp();
  }

  // A reload keeps the number it has until the new one lands.
  Future<void> _loadPlugins() async {
    final n = await hmPluginCount(_api);
    if (mounted) setState(() => _plugins = n);
  }

  Future<void> _loadMcp() async {
    final n = await hmMcpCount(_api);
    if (mounted) setState(() => _mcp = n);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: bots,
    // A Model save refreshes [bots]; the rows show it at once.
    builder: (context, _) =>
        _build(context, bots.byProfile(bot.profile) ?? bot),
  );

  Widget _build(BuildContext context, HmBot bot) {
    final c = NgColors.of(context);
    void push(Widget page) => Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => page));
    return Scaffold(
      backgroundColor: c.background,
      body: Column(
        children: [
          HmTopBar(
            leading: const HmBackButton(),
            trailing: [
              HmRoundButton(
                icon: Icons.add,
                label: 'New Agent',
                onPressed: () => openHmNewAgent(context, bots: bots),
              ),
            ],
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                const SizedBox(height: 8),
                Center(child: HmAvatar(spec: bot.character, size: 96)),
                const SizedBox(height: 12),
                Center(
                  child: Semantics(
                    label: 'Agent name',
                    child: Text(
                      bot.displayName,
                      style: HmType.display.copyWith(color: c.text),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                HmGroup(
                  children: [
                    HmRow(
                      icon: Icons.memory,
                      label: 'Model',
                      value: _prettyModel(bot.model),
                      subValue: bot.provider.isEmpty ? null : bot.provider,
                      tall: true,
                      onTap: () =>
                          openHmModelPage(context, bot: bot, bots: bots),
                    ),
                    HmRow(
                      icon: Icons.view_in_ar_outlined,
                      label: 'Skills',
                      value: '${bot.skillCount}',
                      tall: true,
                      onTap: () => push(const NgCapabilitiesPage()),
                    ),
                  ],
                ),
                const HmSection('Integrations'),
                HmGroup(
                  children: [
                    HmRow(
                      icon: Icons.hub_outlined,
                      label: 'Connections',
                      tall: true,
                      onTap: () =>
                          openHmConnections(context, bot: bot, bots: bots),
                    ),
                    HmRow(
                      icon: Icons.extension_outlined,
                      label: 'Plugins',
                      value: _plugins.label,
                      tall: true,
                      onTap: () async {
                        await openHmPlugins(context, bot: bot, bots: bots);
                        await _loadPlugins();
                      },
                    ),
                    HmRow(
                      icon: Icons.power_outlined,
                      label: 'MCP',
                      value: _mcp.label,
                      tall: true,
                      onTap: () async {
                        await openHmMcp(context, bot: bot, bots: bots);
                        await _loadMcp();
                      },
                    ),
                  ],
                ),
                const HmSection('Work'),
                HmGroup(
                  children: [
                    HmRow(
                      icon: Icons.folder_special_outlined,
                      label: 'Projects',
                      tall: true,
                      onTap: () =>
                          openHmProjects(context, bot: bot, bots: bots),
                    ),
                    HmRow(
                      icon: Icons.schedule,
                      label: 'Routines',
                      tall: true,
                      onTap: () => push(
                        NgScheduledPage(
                          onOpenSession: (_) => Navigator.of(context).pop(),
                        ),
                      ),
                    ),
                    HmRow(
                      icon: Icons.inventory_2_outlined,
                      label: 'Artifacts',
                      tall: true,
                      onTap: () =>
                          openHmArtifacts(context, bot: bot, bots: bots),
                    ),
                    HmRow(
                      icon: Icons.view_kanban_outlined,
                      label: 'Kanban',
                      tall: true,
                      onTap: () => openHmKanban(context, bot: bot, bots: bots),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// `claude-opus-5-5` → `Opus 5.5`; other ids pass through without a vendor prefix.
  static String _prettyModel(String id) {
    final bare = id.contains('/') ? id.substring(id.lastIndexOf('/') + 1) : id;
    final m = RegExp(
      r'^claude-(opus|sonnet|haiku|fable|mythos)-(\d+)-(\d+)',
    ).firstMatch(bare);
    if (m != null) {
      final family = m.group(1)!;
      return '${family[0].toUpperCase()}${family.substring(1)} ${m.group(2)}.${m.group(3)}';
    }
    return bare;
  }
}
