// Model: what the bot runs on. Agent settings → Model opens "Default Model":
// the profile's current main model, the models starred on this phone, a way
// into All models, and Advanced (auxiliary task models, Mixture of Agents).
// Every read and write is scoped to the bot's profile.
import 'package:flutter/material.dart';

import '../../../nextgen/theme/nextgen_theme.dart';
import '../../hm_bots.dart';
import '../../hm_ui.dart';
import 'hm_model_api.dart';
import 'hm_model_picker.dart';

Future<void> openHmModelPage(
  BuildContext context, {
  required HmBot bot,
  required HmBotsModel bots,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => HmModelPage(
      bot: bot,
      api: HmAgentModelApi.of(bots),
      onSaved: bots.refresh,
    ),
  ),
);

/// Assigns [choice] for [profile], asking first when the host flags an
/// expensive model. Reports failure in a snackbar; true when saved.
Future<bool> hmAssignModel(
  BuildContext context, {
  required HmAgentModelApi api,
  required String? profile,
  required HmModelChoice? choice,
  String scope = 'main',
  String task = '',
}) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    var r = await api.setModel(
      profile,
      choice: choice,
      scope: scope,
      task: task,
    );
    if (r.needsConfirm) {
      if (!context.mounted) return false;
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Confirm model change'),
          content: Text(
            r.confirmMessage!.isEmpty
                ? 'This model is expensive. Use it anyway?'
                : r.confirmMessage!,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(MaterialLocalizations.of(ctx).cancelButtonLabel),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Use anyway'),
            ),
          ],
        ),
      );
      if (go != true) return false;
      r = await api.setModel(
        profile,
        choice: choice,
        scope: scope,
        task: task,
        confirmExpensive: true,
      );
    }
    if (!r.ok) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Hermes did not save the model assignment.'),
        ),
      );
      return false;
    }
    return true;
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('The model could not be saved.\n$e')),
    );
    return false;
  }
}

class HmModelPage extends StatefulWidget {
  const HmModelPage({
    super.key,
    required this.bot,
    required this.api,
    this.onSaved,
  });

  final HmBot bot;
  final HmAgentModelApi api;

  /// Runs after a save, so Agent settings shows the new model on return.
  final Future<void> Function()? onSaved;

  @override
  State<HmModelPage> createState() => _HmModelPageState();
}

class _HmModelPageState extends State<HmModelPage> {
  HmModelInfo? _info;
  Object? _error;
  bool _loading = true;
  List<HmModelChoice> _favourites = const [];
  bool _favouritesLoaded = false;
  HmModelChoice? _saving;

  String? get _profile => widget.bot.scope;

  @override
  void initState() {
    super.initState();
    _load();
    _loadFavourites();
  }

  Future<void> _loadFavourites() async {
    final f = await HmModelFavourites.load();
    if (mounted) {
      setState(() {
        _favourites = f;
        _favouritesLoaded = true;
      });
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final info = await widget.api.info(_profile);
      if (!mounted) return;
      setState(() {
        _info = info;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<bool> _assign(HmModelChoice? choice) async {
    if (choice == null) return false;
    setState(() => _saving = choice);
    final ok = await hmAssignModel(
      context,
      api: widget.api,
      profile: _profile,
      choice: choice,
    );
    if (!mounted) return ok;
    setState(() {
      _saving = null;
      if (ok) {
        _info = HmModelInfo(model: choice.model, provider: choice.provider);
      }
    });
    if (ok) {
      await widget.onSaved?.call();
      _load();
    }
    return ok;
  }

  Future<void> _openAll() async {
    await Navigator.of(context).push(
      MaterialPageRoute<bool>(
        builder: (_) => HmModelPickerPage(
          api: widget.api,
          profile: _profile,
          title: 'All models',
          selected: _current,
          onPick: _assign,
        ),
      ),
    );
    _loadFavourites();
  }

  HmModelChoice? get _current {
    final i = _info;
    return i == null || !i.isSet ? null : HmModelChoice(i.provider, i.model);
  }

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return Scaffold(
      backgroundColor: c.background,
      body: Column(
        children: [
          HmTopBar(
            leading: const HmBackButton(),
            title: 'Default Model',
            trailing: [
              TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => HmModelAdvancedPage(
                      bot: widget.bot,
                      api: widget.api,
                      onSaved: widget.onSaved,
                    ),
                  ),
                ),
                child: Text(
                  'Advanced',
                  style: HmType.row.copyWith(
                    color: c.accentText,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          Expanded(child: _body(c)),
        ],
      ),
    );
  }

  Widget _body(NgColors c) {
    if (_loading && _info == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _info == null) {
      return ListView(
        children: [
          HmMessage(
            body: 'Model settings could not be loaded.',
            detail: '$_error',
            action: 'Reload models',
            onAction: _load,
          ),
        ],
      );
    }
    final info = _info!;
    return ListView(
      padding: const EdgeInsets.only(top: 12, bottom: 32),
      children: [
        _currentCard(c, info),
        Padding(
          padding: const EdgeInsets.fromLTRB(32, HmMetrics.groupGap, 20, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Favourites',
                  style: HmType.value.copyWith(color: c.text3),
                ),
              ),
              TextButton(
                onPressed: _openAll,
                child: Text(
                  'All models',
                  style: HmType.value.copyWith(
                    color: c.accentText,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (!_favouritesLoaded)
          const HmMessage(body: 'Loading favourites…')
        else if (_favourites.isEmpty)
          const HmMessage(body: 'Star a model in All models to keep it here.')
        else
          HmGroup(
            children: [
              for (final f in _favourites)
                HmRow(
                  label: hmPrettyModel(f.model),
                  value: f.provider,
                  tall: true,
                  chevron: false,
                  onTap: _saving == null ? () => _assign(f) : null,
                  trailing: _saving == f
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2.2),
                        )
                      : f == _current
                      ? Icon(
                          Icons.check,
                          color: c.accentText,
                          semanticLabel: 'Selected',
                        )
                      : null,
                ),
            ],
          ),
      ],
    );
  }

  /// The highlighted card: what this profile runs on now.
  Widget _currentCard(NgColors c, HmModelInfo info) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: HmMetrics.edge),
      child: Material(
        color: c.accentSoft,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(HmMetrics.groupRadius),
          side: BorderSide(color: c.accent.withValues(alpha: 0.45)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: _openAll,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: c.surface.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.memory, color: c.accentText),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Profile Default',
                        style: HmType.row.copyWith(
                          color: c.text,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        info.isSet
                            ? [
                                hmPrettyModel(info.model),
                                if (info.provider.isNotEmpty) info.provider,
                              ].join(' · ')
                            : 'Inherits the server default',
                        style: HmType.sub.copyWith(color: c.text3),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (_saving != null && _saving == _current)
                  const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.2),
                  )
                else
                  Icon(Icons.chevron_right, color: c.text3),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Advanced: the main slot plus the auxiliary task models and the
/// Mixture-of-Agents slots this profile runs.
class HmModelAdvancedPage extends StatefulWidget {
  const HmModelAdvancedPage({
    super.key,
    required this.bot,
    required this.api,
    this.onSaved,
  });

  final HmBot bot;
  final HmAgentModelApi api;
  final Future<void> Function()? onSaved;

  @override
  State<HmModelAdvancedPage> createState() => _HmModelAdvancedPageState();
}

class _HmModelAdvancedPageState extends State<HmModelAdvancedPage> {
  HmAuxiliary? _aux;
  Object? _auxError;
  HmMoa? _moa;
  Object? _moaError;
  bool _loading = true;

  String? get _profile => widget.bot.scope;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final results = await Future.wait<Object?>([
      widget.api
          .auxiliary(_profile)
          .then<Object?>((v) => v, onError: (Object e) => e),
      widget.api
          .moa(_profile)
          .then<Object?>((v) => v, onError: (Object e) => e),
    ]);
    if (!mounted) return;
    setState(() {
      _loading = false;
      final a = results[0];
      final m = results[1];
      _aux = a is HmAuxiliary ? a : null;
      _auxError = a is HmAuxiliary ? null : a;
      _moa = m is HmMoa ? m : null;
      _moaError = m is HmMoa ? null : m;
    });
  }

  Future<void> _pickFor(HmAuxSlot slot) async {
    await Navigator.of(context).push(
      MaterialPageRoute<bool>(
        builder: (_) => HmModelPickerPage(
          api: widget.api,
          profile: _profile,
          title: slot.label,
          selected: slot.isAuto
              ? null
              : HmModelChoice(slot.provider, slot.model),
          noneLabel: 'Auto — follows main model',
          onPick: (choice) async {
            final ok = await hmAssignModel(
              context,
              api: widget.api,
              profile: _profile,
              choice: choice,
              scope: 'auxiliary',
              task: slot.task,
            );
            if (ok) await widget.onSaved?.call();
            return ok;
          },
        ),
      ),
    );
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return HmPage(
      title: 'Advanced Settings',
      children: [
        if (_loading && _aux == null && _auxError == null)
          const Padding(
            padding: EdgeInsets.only(top: 48),
            child: Center(child: CircularProgressIndicator()),
          )
        else ...[
          if (_auxError != null)
            HmMessage(
              body: 'Model settings could not be loaded.',
              detail: '$_auxError',
              action: 'Reload models',
              onAction: _load,
            )
          else if (_aux != null)
            ..._auxSection(c, _aux!),
          ..._moaSection(c),
        ],
      ],
    );
  }

  List<Widget> _auxSection(NgColors c, HmAuxiliary aux) => [
    const HmSection('Main Model'),
    HmGroup(
      children: [
        HmRow(
          icon: Icons.memory,
          label: aux.main == null
              ? 'Server default'
              : hmPrettyModel(aux.main!.model),
          value: aux.main?.provider,
          chevron: false,
          tall: true,
        ),
      ],
    ),
    const HmSection('Auxiliary'),
    if (aux.tasks.isEmpty)
      const HmMessage(body: 'This profile reports no auxiliary model slots.')
    else
      HmGroup(
        children: [
          for (final t in aux.tasks)
            HmRow(
              label: t.label,
              value: t.isAuto
                  ? 'Auto — follows main model'
                  : hmPrettyModel(t.model),
              subValue: t.isAuto ? null : t.provider,
              tall: true,
              onTap: () => _pickFor(t),
            ),
        ],
      ),
  ];

  List<Widget> _moaSection(NgColors c) {
    if (_moaError != null) {
      return [
        const HmSection('Mixture of Agents'),
        HmMessage(
          body: 'Model settings could not be loaded.',
          detail: '$_moaError',
        ),
      ];
    }
    final moa = _moa;
    if (moa == null) return const [];
    return [
      const HmSection('Mixture of Agents'),
      Padding(
        padding: const EdgeInsets.fromLTRB(32, 0, 32, 10),
        child: Text(
          'Reference models contribute answers that the aggregator combines.',
          style: HmType.caption.copyWith(color: c.text3),
        ),
      ),
      HmGroup(
        children: [
          for (final r in moa.references)
            HmRow(
              icon: Icons.hub_outlined,
              label: hmPrettyModel(r.model),
              value: r.provider,
              chevron: false,
              tall: true,
            ),
          HmRow(
            icon: Icons.merge_type,
            label: 'Aggregator',
            value: moa.aggregator == null
                ? 'Follow main model'
                : hmPrettyModel(moa.aggregator!.model),
            subValue: moa.aggregator?.provider,
            chevron: false,
            tall: true,
          ),
        ],
      ),
    ];
  }
}
