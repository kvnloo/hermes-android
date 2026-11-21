import 'package:flutter/material.dart';

import '../../core/l10n/l10n.dart';
import '../../core/models/bot_directory_document.dart';
import '../features/agent_model/hm_model_api.dart';
import '../hm_bots.dart';

class HmBotImport extends StatefulWidget {
  const HmBotImport({super.key, required this.document, required this.bots});

  final BotDirectoryDocument? document;
  final HmBotsModel bots;

  @override
  State<HmBotImport> createState() => _HmBotImportState();
}

class _HmBotImportState extends State<HmBotImport> {
  bool _saving = false;
  String? _error;

  Future<void> _add(BotDirectoryDocument document) async {
    final bots = widget.bots;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final result = await HmAgentModelApi.of(
        bots,
      ).createProfile(name: document.name, description: document.description);
      if (mounted) {
        Navigator.pop(
          context,
          HmBot.fromJson({
            'name': result.name,
            'display_name': document.title,
            'description': document.description,
          }),
        );
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '$error';
      });
      await bots.refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final document = widget.document;
    final bots = widget.bots;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.ng_bot_import_title)),
      body: ListenableBuilder(
        listenable: bots,
        builder: (context, _) {
          if (document == null) {
            return Padding(
              padding: const EdgeInsets.all(24),
              child: Text(l10n.ng_bot_import_invalid),
            );
          }
          final existing = bots.byProfile(document.name);
          final error = _error ?? bots.error;
          return ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                document.title ?? document.name,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              if (document.title != null) Text(document.name),
              Text(bots.gateway.connection.label),
              if (document.description case final description?) ...[
                const SizedBox(height: 12),
                Text(description),
              ],
              if (error != null) ...[
                const SizedBox(height: 12),
                Text(l10n.ng_couldn_t_save(error)),
              ],
              const SizedBox(height: 24),
              if (_saving || bots.loading)
                const Center(child: CircularProgressIndicator())
              else if (existing != null)
                FilledButton(
                  onPressed: () => Navigator.pop(context, existing),
                  child: Text(l10n.ng_bot_import_open_chat),
                )
              else if (bots.error != null)
                OutlinedButton(
                  onPressed: bots.refresh,
                  child: Text(l10n.ng_try_again),
                )
              else
                FilledButton(
                  onPressed: () => _add(document),
                  child: Text(l10n.ng_bot_import_add),
                ),
            ],
          );
        },
      ),
    );
  }
}
