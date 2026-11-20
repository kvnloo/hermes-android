// AI Elements Persona voice orbs: the original Rive files (Copyright 2023
// Vercel, Inc., Apache-2.0), bundled unchanged from kvnloo/expo-gpt-live and
// checked against its manifest. Notices: third_party/ai-elements-persona/.
//
// Every file has a state machine `default` with booleans listening /
// thinking / speaking / asleep; idle clears all four. The 2.0 files also
// expose a `color` view-model property (Opal and Mana keep their own).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:rive/rive.dart' as rive;

import 'hm_avatar_state.dart';

const _inputs = ['listening', 'thinking', 'speaking', 'asleep'];

/// The Rive runtime, started the first time a Persona orb shows (lazy
/// top-level final). False keeps the plain-disc fallback.
final Future<bool> _runtime = () async {
  try {
    return await rive.RiveNative.init();
  } catch (_) {
    return false;
  }
}();

/// Each variant's file is decoded once and shared for the process lifetime.
final _files = <HmPersonaVariant, Future<rive.File?>>{};

Future<rive.File?> _file(HmPersonaVariant v) => _files.putIfAbsent(
  v,
  () => rive.File.asset(
    'assets/persona/${v.name}.riv',
    riveFactory: rive.Factory.rive,
  ),
);

bool _recolors(HmPersonaVariant v) =>
    v != HmPersonaVariant.opal && v != HmPersonaVariant.mana;

class PersonaOrb extends StatefulWidget {
  const PersonaOrb({
    super.key,
    required this.variant,
    required this.state,
    required this.size,
    required this.color,
    this.animate = true,
  });

  final HmPersonaVariant variant;
  final HmAvatarState state;
  final double size;

  /// Ink for the mono looks (Obsidian, Halo, Glint, Command).
  final Color color;
  final bool animate;

  @override
  State<PersonaOrb> createState() => _PersonaOrbState();
}

class _PersonaOrbState extends State<PersonaOrb> {
  rive.RiveWidgetController? _controller;
  rive.ViewModelInstance? _vm;
  int _load = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  @override
  void didUpdateWidget(PersonaOrb old) {
    super.didUpdateWidget(old);
    if (old.variant != widget.variant) {
      _close();
      unawaited(_open());
    } else {
      _apply();
    }
  }

  @override
  void dispose() {
    _close();
    super.dispose();
  }

  Future<void> _open() async {
    final load = ++_load;
    if (!await _runtime) return;
    final file = await _file(widget.variant);
    // A newer variant (or dispose) won while this one loaded.
    if (!mounted || load != _load || file == null) return;
    final c = rive.RiveWidgetController(
      file,
      stateMachineSelector: rive.StateMachineSelector.byName('default'),
    );
    rive.ViewModelInstance? vm;
    if (_recolors(widget.variant)) {
      try {
        vm = c.dataBind(rive.DataBind.auto());
      } catch (_) {
        vm = null;
      }
    }
    setState(() {
      _controller = c;
      _vm = vm;
    });
    _apply();
  }

  void _close() {
    _load++;
    _vm?.dispose();
    _controller?.dispose();
    _vm = null;
    _controller = null;
  }

  void _apply() {
    final c = _controller;
    if (c == null) return;
    for (final name in _inputs) {
      c.stateMachine.boolean(name)?.value = switch (widget.state) {
        HmAvatarState.listening => name == 'listening',
        HmAvatarState.thinking => name == 'thinking',
        HmAvatarState.speaking => name == 'speaking',
        HmAvatarState.asleep => name == 'asleep',
        HmAvatarState.idle || HmAvatarState.error => false,
      };
    }
    _vm?.color('color')?.value = widget.state == HmAvatarState.error
        ? const Color(0xFFE5522D)
        : widget.color;
    c.active = widget.animate;
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    return SizedBox.square(
      dimension: widget.size,
      child: c == null
          ? DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.color.withValues(alpha: 0.12),
              ),
            )
          : rive.RiveWidget(controller: c, fit: rive.Fit.contain),
    );
  }
}
