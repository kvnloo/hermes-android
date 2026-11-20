// Agent settings: the bot's character and name, what it runs on, its
// integrations and its work. Rows whose Hermes-style page isn't rebuilt yet
// open the existing NextGen page for the same data.
import 'package:flutter/material.dart';

import '../../nextgen/theme/nextgen_theme.dart';
import '../../nextgen/ui/capabilities_page.dart';
import '../../nextgen/ui/scheduled_page.dart';
import '../hm_bots.dart';
import '../avatar/hm_avatar.dart';
import '../hm_ui.dart';

class HmAgentScreen extends StatelessWidget {
  const HmAgentScreen({super.key, required this.bot, required this.bots});

  final HmBot bot;
  final HmBotsModel bots;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    void push(Widget page) => Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => page));
    void soon(String what) => ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$what is coming next')));
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
                onPressed: () => soon('New Agent'),
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
                      onTap: () => soon('Model'),
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
                      onTap: () => soon('Connections'),
                    ),
                    HmRow(
                      icon: Icons.extension_outlined,
                      label: 'Plugins',
                      tall: true,
                      onTap: () => soon('Plugins'),
                    ),
                    HmRow(
                      icon: Icons.power_outlined,
                      label: 'MCP',
                      tall: true,
                      onTap: () => soon('MCP'),
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
                      onTap: () => soon('Projects'),
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
                      onTap: () => soon('Artifacts'),
                    ),
                    HmRow(
                      icon: Icons.view_kanban_outlined,
                      label: 'Kanban',
                      tall: true,
                      onTap: () => soon('Kanban'),
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
