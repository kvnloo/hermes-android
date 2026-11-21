// New Agent: create a bot, which is a host profile. The name is the profile
// id; the host validates it and its refusal is shown as sent. The bot's look
// is stored in the profile's `ui_meta.character` once the profile exists.
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../nextgen/theme/nextgen_theme.dart';
import '../../avatar/hm_avatar.dart';
import '../../hm_bots.dart';
import '../../hm_ui.dart';
import 'hm_model_api.dart';
import 'hm_model_picker.dart';

Future<void> openHmNewAgent(
  BuildContext context, {
  required HmBotsModel bots,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => HmNewAgentPage(
      api: HmAgentModelApi.of(bots),
      bots: bots.bots,
      onCreated: bots.refresh,
    ),
  ),
);

/// The host's profile id rule (`hermes_constants.PROFILE_ID_RE`).
final hmProfileNamePattern = RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$');

const hmProfileNameRule =
    'Use a profile name of up to 64 Latin letters, numbers, hyphens or '
    'underscores. You can change the display name afterward.';

class HmNewAgentPage extends StatefulWidget {
  const HmNewAgentPage({
    super.key,
    required this.api,
    required this.bots,
    this.onCreated,
    this.random,
  });

  final HmAgentModelApi api;

  /// The host's bots, to clone config from.
  final List<HmBot> bots;

  /// Runs after the profile exists (reload Home's bots).
  final Future<void> Function()? onCreated;

  /// Seeds the first face; tests pass a fixed one.
  final Random? random;

  @override
  State<HmNewAgentPage> createState() => _HmNewAgentPageState();
}

class _HmNewAgentPageState extends State<HmNewAgentPage> {
  final _name = TextEditingController();
  final _description = TextEditingController();
  late HmCharacterSpec _look;
  HmModelChoice? _model;
  String _soul = '';
  late String _cloneFrom;
  bool _saving = false;
  String? _hostError;

  @override
  void initState() {
    super.initState();
    final rng = widget.random ?? Random();
    final seed = rng.nextInt(0x7FFFFFFF);
    _look = HmCharacterSpec(
      seed: seed,
      color: HmCharacterSpec.palette[seed % HmCharacterSpec.palette.length],
    );
    _cloneFrom =
        widget.bots.where((b) => b.isDefault).firstOrNull?.profile ??
        widget.bots.firstOrNull?.profile ??
        'default';
    _name.addListener(_nameChanged);
  }

  String _lastName = '';

  /// A new name clears the host's refusal of the old one; focus and
  /// selection changes do not.
  void _nameChanged() {
    if (_name.text == _lastName) return;
    _lastName = _name.text;
    setState(() => _hostError = null);
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  String get _nameText => _name.text.trim();
  bool get _nameValid =>
      hmProfileNamePattern.hasMatch(_nameText) && _nameText != 'default';

  HmBot? get _source =>
      widget.bots.where((b) => b.profile == _cloneFrom).firstOrNull;

  String get _sourceLabel =>
      _source?.displayName ?? (_cloneFrom == 'default' ? 'Hermes' : _cloneFrom);

  Future<void> _create() async {
    if (!_nameValid || _saving) return;
    setState(() {
      _saving = true;
      _hostError = null;
    });
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      final created = await widget.api.createProfile(
        name: _nameText,
        description: _description.text,
        soul: _soul,
        model: _model,
        cloneFrom: _cloneFrom,
      );
      final pictured = await widget.api.setCharacter(
        created.name,
        _look.toMeta(),
      );
      if (!pictured) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Couldn\'t give the new agent its picture'),
          ),
        );
      }
      if (created.modelError != null) {
        messenger.showSnackBar(SnackBar(content: Text(created.modelError!)));
      }
      await widget.onCreated?.call();
      if (mounted) navigator.pop(created.name);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _hostError = '$e';
      });
    }
  }

  Future<void> _pickModel() async {
    await Navigator.of(context).push(
      MaterialPageRoute<bool>(
        builder: (_) => HmModelPickerPage(
          api: widget.api,
          // The new profile starts from its clone source's config.
          profile:
              _source?.scope ?? (_cloneFrom == 'default' ? null : _cloneFrom),
          title: 'Default Model',
          selected: _model,
          noneLabel: 'Server default',
          noneSubtitle: 'Inherits the server default',
          onPick: (choice) async {
            setState(() => _model = choice);
            return true;
          },
        ),
      ),
    );
  }

  Future<void> _editSoul() async {
    final text = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => _HmSoulEditor(initial: _soul)),
    );
    if (text != null && mounted) setState(() => _soul = text);
  }

  Future<void> _pickClone() async {
    final c = NgColors.of(context);
    final sources = widget.bots.isEmpty
        ? const [('default', 'Hermes')]
        : [for (final b in widget.bots) (b.profile, b.displayName)];
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: c.surface,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                'Clone Config From',
                style: HmType.screenTitle.copyWith(color: c.text),
              ),
            ),
            for (final (profile, label) in sources)
              ListTile(
                title: Text(label, style: HmType.row.copyWith(color: c.text)),
                trailing: profile == _cloneFrom
                    ? Icon(Icons.check, color: c.accentText)
                    : null,
                onTap: () => Navigator.of(ctx).pop(profile),
              ),
          ],
        ),
      ),
    );
    if (picked != null && mounted) setState(() => _cloneFrom = picked);
  }

  Future<void> _editLook() async {
    final c = NgColors.of(context);
    final picked = await showModalBottomSheet<HmCharacterSpec>(
      context: context,
      backgroundColor: c.surface,
      showDragHandle: true,
      builder: (ctx) => _HmLookSheet(initial: _look),
    );
    if (picked != null && mounted) setState(() => _look = picked);
  }

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    final showRule = _nameText.isNotEmpty && !_nameValid;
    return Scaffold(
      backgroundColor: c.background,
      body: Column(
        children: [
          const HmTopBar(leading: HmBackButton(), title: 'Create a New Agent'),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(top: 12, bottom: 24),
              children: [
                Center(
                  child: Semantics(
                    button: true,
                    label: 'Edit agent image',
                    excludeSemantics: true,
                    child: GestureDetector(
                      onTap: _saving ? null : _editLook,
                      child: HmAvatar(spec: _look, size: 120),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Semantics(
                    label: 'Name',
                    child: TextField(
                      controller: _name,
                      enabled: !_saving,
                      textAlign: TextAlign.center,
                      autocorrect: false,
                      enableSuggestions: false,
                      textInputAction: TextInputAction.done,
                      inputFormatters: [_ProfileNameFormatter()],
                      style: HmType.display.copyWith(color: c.text),
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        hintText: 'agent-name',
                        hintStyle: HmType.display.copyWith(color: c.textMuted),
                      ),
                    ),
                  ),
                ),
                if (showRule)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(32, 0, 32, 8),
                    child: Text(
                      hmProfileNameRule,
                      textAlign: TextAlign.center,
                      style: HmType.caption.copyWith(color: c.danger),
                    ),
                  ),
                const SizedBox(height: 12),
                _card(
                  c,
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Description',
                          style: HmType.value.copyWith(color: c.text),
                        ),
                        TextField(
                          controller: _description,
                          enabled: !_saving,
                          minLines: 2,
                          maxLines: 5,
                          style: HmType.value.copyWith(color: c.text),
                          decoration: InputDecoration(
                            border: InputBorder.none,
                            hintText: 'What is this agent good at?',
                            hintStyle: HmType.value.copyWith(
                              color: c.textMuted,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                _card(
                  c,
                  HmRow(
                    icon: Icons.memory,
                    label: 'Default Model',
                    value: _model == null
                        ? 'Server default'
                        : hmPrettyModel(_model!.model),
                    subValue: _model?.provider,
                    tall: true,
                    onTap: _saving ? null : _pickModel,
                  ),
                ),
                _card(
                  c,
                  HmRow(
                    icon: Icons.auto_awesome,
                    label: 'Soul',
                    value: _soul.trim().isEmpty ? null : _firstLine(_soul),
                    tall: true,
                    onTap: _saving ? null : _editSoul,
                  ),
                ),
                _card(
                  c,
                  HmRow(
                    icon: Icons.copy_all_outlined,
                    label: 'Clone Config From',
                    value: _sourceLabel,
                    tall: true,
                    chevron: false,
                    trailing: Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Icon(Icons.unfold_more, color: c.text3),
                    ),
                    onTap: _saving ? null : _pickClone,
                  ),
                ),
              ],
            ),
          ),
          if (_hostError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
              child: Text(
                _hostError!,
                textAlign: TextAlign.center,
                style: HmType.value.copyWith(color: c.danger),
              ),
            ),
          SafeArea(
            top: false,
            child: HmPrimaryButton(
              label: 'Create Agent',
              trailingIcon: Icons.add,
              busy: _saving,
              onPressed: _nameValid ? _create : null,
            ),
          ),
        ],
      ),
    );
  }

  static String _firstLine(String s) {
    final line = s.trim().split('\n').first.trim();
    return line.length > 24 ? '${line.substring(0, 24)}…' : line;
  }

  Widget _card(NgColors c, Widget child) => Padding(
    padding: const EdgeInsets.fromLTRB(HmMetrics.edge, 0, HmMetrics.edge, 14),
    child: Material(
      color: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(HmMetrics.groupRadius),
        side: BorderSide(color: c.stroke),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: child,
      ),
    ),
  );
}

/// Profile ids are lowercase with no spaces; type them that way.
class _ProfileNameFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = newValue.text.toLowerCase().replaceAll(' ', '-');
    return newValue.copyWith(text: text);
  }
}

/// Pick the bot's tone and face.
class _HmLookSheet extends StatefulWidget {
  const _HmLookSheet({required this.initial});
  final HmCharacterSpec initial;

  @override
  State<_HmLookSheet> createState() => _HmLookSheetState();
}

class _HmLookSheetState extends State<_HmLookSheet> {
  late HmCharacterSpec _spec = widget.initial;
  final _rng = Random();

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            HmAvatar(spec: _spec, size: 96),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () => setState(
                () => _spec = HmCharacterSpec(
                  seed: _rng.nextInt(0x7FFFFFFF),
                  color: _spec.color,
                ),
              ),
              icon: Icon(Icons.shuffle, color: c.accentText),
              label: Text(
                'Shuffle',
                style: HmType.value.copyWith(color: c.accentText),
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Palettes',
                style: HmType.section.copyWith(color: c.text3),
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final (i, tone) in HmCharacterSpec.palette.indexed)
                  Semantics(
                    button: true,
                    selected: _spec.tone == tone,
                    label: 'Palette ${i + 1}',
                    excludeSemantics: true,
                    child: GestureDetector(
                      onTap: () => setState(
                        () => _spec = HmCharacterSpec(
                          seed: _spec.seed,
                          color: tone,
                        ),
                      ),
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          // A bot tone, not a UI colour: it is what the
                          // avatar draws in.
                          color: tone,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: _spec.tone == tone ? c.text : c.stroke,
                            width: _spec.tone == tone ? 3 : 1,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            HmPrimaryButton(
              label: 'Use',
              trailingIcon: Icons.check,
              onPressed: () => Navigator.of(context).pop(_spec),
            ),
          ],
        ),
      ),
    );
  }
}

/// Soul: the agent's SOUL.md, written before it exists.
class _HmSoulEditor extends StatefulWidget {
  const _HmSoulEditor({required this.initial});
  final String initial;

  @override
  State<_HmSoulEditor> createState() => _HmSoulEditorState();
}

class _HmSoulEditorState extends State<_HmSoulEditor> {
  late final _text = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
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
            title: 'Soul',
            trailing: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(_text.text),
                child: Text(
                  MaterialLocalizations.of(context).saveButtonLabel,
                  style: HmType.row.copyWith(
                    color: c.accentText,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                HmMetrics.edge,
                8,
                HmMetrics.edge,
                16,
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(HmMetrics.groupRadius),
                  border: Border.all(color: c.stroke),
                ),
                child: TextField(
                  controller: _text,
                  autofocus: true,
                  expands: true,
                  maxLines: null,
                  textAlignVertical: TextAlignVertical.top,
                  style: HmType.body.copyWith(color: c.text),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintText: 'SOUL.md',
                    hintStyle: HmType.body.copyWith(color: c.textMuted),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
