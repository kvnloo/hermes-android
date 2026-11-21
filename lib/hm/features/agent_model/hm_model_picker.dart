// All models: the host's catalog for one profile, grouped by provider, with
// search and favourites. Model and New Agent both pick from it.
import 'package:flutter/material.dart';

import '../../../nextgen/theme/nextgen_theme.dart';
import '../../hm_ui.dart';
import 'hm_model_api.dart';

class HmModelPickerPage extends StatefulWidget {
  const HmModelPickerPage({
    super.key,
    required this.api,
    required this.profile,
    required this.onPick,
    this.selected,
    this.title = 'Choose Model',
    this.noneLabel,
    this.noneSubtitle,
  });

  final HmAgentModelApi api;

  /// The profile whose catalog to list (null: the host's default).
  final String? profile;
  final HmModelChoice? selected;
  final String title;

  /// A first row that picks no model (Server default, Auto…); hidden when null.
  final String? noneLabel;
  final String? noneSubtitle;

  /// Applies the pick; true closes the picker.
  final Future<bool> Function(HmModelChoice? choice) onPick;

  @override
  State<HmModelPickerPage> createState() => _HmModelPickerPageState();
}

class _HmModelPickerPageState extends State<HmModelPickerPage> {
  HmModelCatalog? _catalog;
  Object? _error;
  bool _loading = true;
  List<HmModelChoice> _favourites = const [];
  String _query = '';
  HmModelChoice? _busy;
  bool _busyNone = false;

  @override
  void initState() {
    super.initState();
    _load();
    HmModelFavourites.load().then((f) {
      if (mounted) setState(() => _favourites = f);
    });
  }

  Future<void> _load({bool refresh = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final c = await widget.api.options(widget.profile, refresh: refresh);
      if (!mounted) return;
      setState(() {
        _catalog = c;
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

  Future<void> _pick(HmModelChoice? choice) async {
    if (_busy != null || _busyNone) return;
    setState(() {
      _busy = choice;
      _busyNone = choice == null;
    });
    var close = false;
    try {
      close = await widget.onPick(choice);
    } finally {
      if (mounted) {
        setState(() {
          _busy = null;
          _busyNone = false;
        });
      }
    }
    if (close && mounted) Navigator.of(context).pop(true);
  }

  Future<void> _star(HmModelChoice choice) async {
    final f = await HmModelFavourites.toggle(choice);
    if (mounted) setState(() => _favourites = f);
  }

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return Scaffold(
      backgroundColor: c.background,
      body: Column(
        children: [
          HmTopBar(leading: const HmBackButton(), title: widget.title),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              HmMetrics.edge,
              4,
              HmMetrics.edge,
              8,
            ),
            child: TextField(
              onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
              style: HmType.value.copyWith(color: c.text),
              decoration: InputDecoration(
                hintText: 'Search all models',
                hintStyle: HmType.value.copyWith(color: c.textMuted),
                prefixIcon: Icon(Icons.search, color: c.text3),
                filled: true,
                fillColor: c.surface,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(HmMetrics.groupRadius),
                  borderSide: BorderSide(color: c.stroke),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(HmMetrics.groupRadius),
                  borderSide: BorderSide(color: c.stroke),
                ),
              ),
            ),
          ),
          Expanded(child: _body(c)),
        ],
      ),
    );
  }

  Widget _body(NgColors c) {
    final none = widget.noneLabel == null
        ? null
        : HmGroup(
            children: [
              HmRow(
                icon: Icons.dns_outlined,
                label: widget.noneLabel!,
                value: widget.noneSubtitle,
                chevron: false,
                tall: true,
                trailing: _trailingFor(
                  c,
                  selected: widget.selected == null,
                  busy: _busyNone,
                ),
                onTap: () => _pick(null),
              ),
            ],
          );
    if (_loading) {
      return ListView(
        children: [
          ?none,
          const SizedBox(height: 48),
          const Center(child: CircularProgressIndicator()),
        ],
      );
    }
    if (_error != null) {
      return ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          ?none,
          HmMessage(
            title: 'Models unavailable',
            body: widget.noneLabel != null
                ? 'Models couldn’t be loaded. You can still use the server default.'
                : 'Model settings could not be loaded.',
            detail: '$_error',
            action: 'Reload models',
            onAction: () => _load(refresh: true),
          ),
        ],
      );
    }
    final catalog = _catalog!;
    if (catalog.isEmpty) {
      return ListView(
        children: [
          ?none,
          const HmMessage(
            title: 'No models to show',
            body: 'No models are configured.',
          ),
        ],
      );
    }
    bool matches(String provider, String name, String model) =>
        _query.isEmpty ||
        model.toLowerCase().contains(_query) ||
        hmPrettyModel(model).toLowerCase().contains(_query) ||
        provider.toLowerCase().contains(_query) ||
        name.toLowerCase().contains(_query);
    final sections = <Widget>[];
    for (final p in catalog.providers) {
      final models = [
        for (final m in p.models)
          if (matches(p.slug, p.name, m)) m,
      ];
      if (models.isEmpty) continue;
      sections
        ..add(HmSection(p.name))
        ..add(
          HmGroup(
            children: [
              if (p.warning != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Text(
                    p.warning!,
                    style: HmType.caption.copyWith(color: c.text3),
                  ),
                ),
              for (final m in models) _modelRow(c, HmModelChoice(p.slug, m)),
            ],
          ),
        );
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        ?none,
        if (sections.isEmpty)
          const HmMessage(
            title: 'No models to show',
            body: 'Nothing matches this search.',
          )
        else
          ...sections,
      ],
    );
  }

  Widget _modelRow(NgColors c, HmModelChoice choice) {
    final starred = _favourites.contains(choice);
    final pretty = hmPrettyModel(choice.model);
    return HmRow(
      label: pretty,
      value: pretty == choice.model ? null : choice.model,
      chevron: false,
      tall: true,
      onTap: () => _pick(choice),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _trailingFor(
                c,
                selected: widget.selected == choice,
                busy: _busy == choice,
              ) ??
              const SizedBox(width: 24),
          IconButton(
            tooltip: starred ? 'Remove from favourites' : 'Add to favourites',
            icon: Icon(
              starred ? Icons.star_rounded : Icons.star_outline_rounded,
              color: starred ? c.accentText : c.text3,
            ),
            onPressed: () => _star(choice),
          ),
        ],
      ),
    );
  }

  Widget? _trailingFor(
    NgColors c, {
    required bool selected,
    required bool busy,
  }) {
    if (busy) {
      return const SizedBox.square(
        dimension: 20,
        child: CircularProgressIndicator(strokeWidth: 2.2),
      );
    }
    return selected
        ? Icon(Icons.check, color: c.accentText, semanticLabel: 'Selected')
        : null;
  }
}

/// A centred empty / error notice, with an optional action.
class HmMessage extends StatelessWidget {
  const HmMessage({
    super.key,
    this.title,
    required this.body,
    this.detail,
    this.action,
    this.onAction,
  });

  final String? title;
  final String body;
  final String? detail;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 40, 32, 16),
      child: Column(
        children: [
          if (title != null) ...[
            Text(
              title!,
              textAlign: TextAlign.center,
              style: HmType.row.copyWith(
                color: c.text,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
          ],
          Text(
            body,
            textAlign: TextAlign.center,
            style: HmType.value.copyWith(color: c.text3),
          ),
          if (detail != null && detail!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              detail!,
              textAlign: TextAlign.center,
              style: HmType.caption.copyWith(color: c.textMuted),
            ),
          ],
          if (action != null) ...[
            const SizedBox(height: 16),
            TextButton(
              onPressed: onAction,
              child: Text(
                action!,
                style: HmType.pill.copyWith(color: c.accentText),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
