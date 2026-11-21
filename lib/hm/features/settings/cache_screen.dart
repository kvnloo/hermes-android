// Settings → Caching: which kinds of data stay on this device, how many
// chats, and how much is kept right now. Matches the official Caching page
// (crawl s014). Turning a kind off deletes what was kept for it.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../nextgen/theme/nextgen_theme.dart';
import '../../hm_ui.dart';
import 'cache_store.dart';
import 'settings_kit.dart';
import 'settings_prefs.dart';

class HmCachingScreen extends StatefulWidget {
  const HmCachingScreen({super.key, this.store});
  final HmCacheStore? store;

  @override
  State<HmCachingScreen> createState() => _HmCachingScreenState();
}

class _HmCachingScreenState extends State<HmCachingScreen> {
  late final HmCacheStore _store = widget.store ?? HmCacheStore.instance;
  HmSettingsPrefs get _prefs => _store.prefs;

  HmCacheUsage? _usage;
  bool _usageFailed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadUsage());
  }

  Future<void> _loadUsage() async {
    try {
      final u = await _store.usage();
      if (mounted) {
        setState(() {
          _usage = u;
          _usageFailed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _usageFailed = true);
    }
  }

  Future<void> _toggle(
    HmCacheKind kind,
    bool on,
    Future<bool> Function(bool) set,
  ) async {
    final ok = await set(on);
    if (!ok) {
      if (mounted) hmSettingsToast(context, "Couldn't save this setting.");
      return;
    }
    if (!on) {
      try {
        await _store.clear(kind);
      } catch (_) {}
    }
    await _loadUsage();
  }

  Future<void> _limit(HmCacheLimit l) async {
    final ok = await _prefs.setCacheLimit(l);
    if (!ok) {
      if (mounted) hmSettingsToast(context, "Couldn't save this setting.");
      return;
    }
    try {
      await _store.enforceLimit();
    } catch (_) {}
    await _loadUsage();
  }

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return ListenableBuilder(
      listenable: _prefs,
      builder: (context, _) => HmPage(
        title: 'Caching',
        children: [
          HmSettingsCard(
            icon: Icons.storage,
            title: 'Cached On This Device',
            footnote:
                'Turning one off deletes what was already kept for it. Nothing is removed from the server.',
            children: [
              HmToggleTile(
                icon: Icons.chat,
                title: 'Chat List',
                description:
                    'Titles, previews and dates, so the list is there before the server answers.',
                value: _prefs.cacheChatList,
                onChanged: (v) => _toggle(
                  HmCacheKind.chatList,
                  v,
                  _prefs.setCacheChatList,
                ),
              ),
              HmToggleTile(
                icon: Icons.chat,
                title: 'Messages',
                description:
                    'Whole conversations, so a chat opens instantly and can be read offline.',
                value: _prefs.cacheMessages,
                onChanged: (v) => _toggle(
                  HmCacheKind.messages,
                  v,
                  _prefs.setCacheMessages,
                ),
              ),
              HmToggleTile(
                icon: Icons.attach_file,
                title: 'Files & Links',
                description:
                    'The files, images and links mined from recent chats.',
                value: _prefs.cacheFiles,
                onChanged: (v) =>
                    _toggle(HmCacheKind.files, v, _prefs.setCacheFiles),
              ),
            ],
          ),
          HmSettingsCard(
            icon: Icons.sd_card,
            title: 'Limit',
            footnote: _prefs.cacheLimit.description,
            children: [
              PopupMenuButton<HmCacheLimit>(
                key: const ValueKey('hm-cache-limit'),
                initialValue: _prefs.cacheLimit,
                onSelected: (l) => unawaited(_limit(l)),
                color: c.sheet,
                itemBuilder: (context) => [
                  for (final l in HmCacheLimit.values)
                    PopupMenuItem(
                      value: l,
                      child: Text(
                        l.label,
                        style: HmType.row.copyWith(color: c.text),
                      ),
                    ),
                ],
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    color: c.input,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: c.stroke),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Keep Up To: ${_prefs.cacheLimit.label}',
                          style: HmType.row.copyWith(color: c.text),
                        ),
                      ),
                      Icon(Icons.unfold_more, color: c.text2),
                    ],
                  ),
                ),
              ),
            ],
          ),
          HmSettingsCard(
            icon: Icons.bar_chart,
            title: 'Usage',
            footnote: 'Older items are dropped first once the limit is reached.',
            children: [
              if (_usageFailed)
                Text(
                  "Couldn't read what is kept on this device.",
                  style: HmType.value.copyWith(color: c.danger),
                )
              else if (_usage == null)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Center(
                    child: SizedBox.square(
                      dimension: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.4),
                    ),
                  ),
                )
              else ...[
                _UsageLine('On This Device', hmFormatBytes(_usage!.bytes)),
                _UsageLine('Bots', '${_usage!.bots}'),
                _UsageLine('Chat List', '${_usage!.chatList}'),
                _UsageLine(
                  'Messages',
                  _usage!.messageChats == 1
                      ? '1 chat'
                      : '${_usage!.messageChats} chats',
                ),
                _UsageLine('Files & Links', '${_usage!.files}'),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// LABEL ........ value
class _UsageLine extends StatelessWidget {
  const _UsageLine(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // The label keeps up to three quarters of the free width; the
          // leader fills what's left.
          Flexible(
            flex: 3,
            child: Text(
              label.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HmType.value.copyWith(color: c.text3, letterSpacing: 2.4),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                '.' * 80,
                maxLines: 1,
                overflow: TextOverflow.clip,
                softWrap: false,
                style: HmType.value.copyWith(
                  color: c.textMuted,
                  letterSpacing: 3,
                ),
              ),
            ),
          ),
          Text(value, style: HmType.row.copyWith(color: c.text)),
        ],
      ),
    );
  }
}
