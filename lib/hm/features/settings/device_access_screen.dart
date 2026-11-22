// Settings → Device access: the five on-device sources, each off by default,
// with its permission state and a grant/manage action. The page is Flutter so
// it follows the app theme and leads with the same back bar as every other
// settings page; the state, toggles and permission prompts stay native behind
// [HmDeviceAccessBackend.channel].
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../nextgen/theme/nextgen_theme.dart';
import '../../hm_ui.dart';
import 'settings_kit.dart';

/// One source as the native side reports it.
@immutable
class HmDeviceSource {
  const HmDeviceSource({
    required this.id,
    required this.label,
    required this.enabled,
    required this.state,
    required this.canRequest,
  });

  factory HmDeviceSource.fromMap(Map<Object?, Object?> m) => HmDeviceSource(
    id: m['source']! as String,
    label: m['label']! as String,
    enabled: m['enabled'] == true,
    state: m['state']! as String,
    canRequest: m['canRequest'] == true,
  );

  final String id;
  final String label;
  final bool enabled;
  final String state;
  final bool canRequest;
}

/// The native Device access backend; tests swap in a fake.
class HmDeviceAccessBackend {
  const HmDeviceAccessBackend();

  static const channel = MethodChannel(
    'com.hermesagent.hermes_android/device_access',
  );

  Future<List<HmDeviceSource>> states() async {
    final raw = await channel.invokeListMethod<Object?>('states') ?? const [];
    return [
      for (final e in raw) HmDeviceSource.fromMap(e! as Map<Object?, Object?>),
    ];
  }

  Future<void> setEnabled(String source, bool enabled) => channel
      .invokeMethod<void>('setEnabled', {'source': source, 'enabled': enabled});

  /// False when no permission prompt or settings page could be opened.
  Future<bool> request(String source) async =>
      await channel.invokeMethod<bool>('requestSource', {'source': source}) ??
      false;
}

class HmDeviceAccessScreen extends StatefulWidget {
  const HmDeviceAccessScreen({
    super.key,
    this.backend = const HmDeviceAccessBackend(),
  });

  final HmDeviceAccessBackend backend;

  @override
  State<HmDeviceAccessScreen> createState() => _HmDeviceAccessScreenState();
}

class _HmDeviceAccessScreenState extends State<HmDeviceAccessScreen>
    with WidgetsBindingObserver {
  List<HmDeviceSource>? _sources;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Back from Android Settings: a permission may have changed.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final generation = ++_generation;
    try {
      final sources = await widget.backend.states();
      if (mounted && generation == _generation) {
        setState(() => _sources = sources);
      }
    } on PlatformException {
      if (mounted && generation == _generation) {
        setState(() => _sources = const []);
      }
    } on MissingPluginException {
      if (mounted && generation == _generation) {
        setState(() => _sources = const []);
      }
    }
  }

  Future<void> _toggle(HmDeviceSource source, bool on) async {
    await widget.backend.setEnabled(source.id, on);
    await _refresh();
  }

  Future<void> _request(HmDeviceSource source) async {
    var ok = false;
    try {
      ok = await widget.backend.request(source.id);
    } on PlatformException {
      ok = false;
    }
    if (!mounted) return;
    if (!ok) hmSettingsToast(context, 'Permission settings are unavailable.');
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    final sources = _sources;
    return HmPage(
      title: 'Device access',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 0, 32, HmMetrics.groupGap),
          child: Text(
            'Sources are off by default. '
            'This build does not send device data to a host.',
            style: HmType.value.copyWith(color: c.text3),
          ),
        ),
        if (sources != null && sources.isNotEmpty)
          HmGroup(
            children: [
              for (final s in sources) ...[
                HmSwitchRow(
                  label: '${s.label} · ${s.state}',
                  value: s.enabled,
                  onChanged: (on) => _toggle(s, on),
                ),
                if (s.canRequest)
                  HmRow(
                    label: 'Grant or manage ${s.label} permission',
                    onTap: () => _request(s),
                  ),
              ],
            ],
          )
        else if (sources != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              'Device access is unavailable.',
              style: HmType.value.copyWith(color: c.text3),
            ),
          ),
      ],
    );
  }
}
