// Settings → Security: require the device owner (biometrics or the screen
// lock) when Hermes opens, how long it may stay unlocked in the background,
// and Lock Now. Matches the official Security page (crawl s013).
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../nextgen/theme/nextgen_theme.dart';
import '../../hm_ui.dart';
import 'app_lock.dart';
import 'settings_kit.dart';
import 'settings_prefs.dart';

class HmSecurityScreen extends StatefulWidget {
  const HmSecurityScreen({
    super.key,
    this.lock,
    this.openSecuritySettings = hmOpenAndroidSecuritySettings,
  });

  final HmAppLock? lock;
  final HmOpenSecuritySettings openSecuritySettings;

  @override
  State<HmSecurityScreen> createState() => _HmSecurityScreenState();
}

class _HmSecurityScreenState extends State<HmSecurityScreen>
    with WidgetsBindingObserver {
  late final HmAppLock _lock = widget.lock ?? HmAppLock.instance;
  HmSettingsPrefs get _prefs => _lock.prefs;

  /// Null while the device is being asked.
  HmLockCapability? _capability;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_check());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Back from Android Settings: a screen lock may have been added.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_check());
  }

  Future<void> _check() async {
    final cap = await _lock.authenticator.capability();
    if (mounted) setState(() => _capability = cap);
  }

  Future<void> _toggle(bool on) async {
    setState(() => _busy = true);
    try {
      final result = await _lock.confirmChange(on);
      if (!mounted) return;
      if (result != HmAuthResult.success) {
        final msg = hmAuthMessage(result);
        if (msg != null) hmSettingsToast(context, msg);
        if (result == HmAuthResult.noCredentials) unawaited(_check());
        return;
      }
      final saved = await _prefs.setLockEnabled(on);
      if (!mounted) return;
      if (!saved) hmSettingsToast(context, "Couldn't save the lock setting.");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _grace(HmLockGrace g) async {
    final saved = await _prefs.setLockGrace(g);
    if (!saved && mounted) {
      hmSettingsToast(context, 'Couldn’t save the grace period.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return ListenableBuilder(
      listenable: _prefs,
      builder: (context, _) {
        final cap = _capability;
        final available = cap?.available ?? false;
        final on = _prefs.lockEnabled;
        return HmPage(
          title: 'Security',
          children: [
            HmSettingsCard(
              footnote: cap == null
                  ? null
                  : available
                  ? 'Conversations, files and instance credentials stay covered until the device owner is authenticated. The device screen lock always works as a fallback, so a failed scan cannot lock you out.'
                  : 'This device has no screen lock or biometrics set up. Add one in Android Settings to use the lock.',
              children: [
                HmToggleTile(
                  icon: cap?.face == true ? Icons.face : Icons.fingerprint,
                  title: 'Require ${cap?.method ?? 'Screen Lock'}',
                  description: 'Asked for when the app opens.',
                  value: on,
                  // Turning it off stays possible even if the device lost
                  // its screen lock, so nobody is stuck behind it.
                  onChanged: _busy || cap == null || (!available && !on)
                      ? null
                      : _toggle,
                ),
                if (cap != null && !available) ...[
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: c.accentSoft,
                        foregroundColor: c.accentText,
                        shape: const StadiumBorder(),
                      ),
                      onPressed: () async {
                        final opened = await widget.openSecuritySettings();
                        if (!opened && context.mounted) {
                          hmSettingsToast(
                            context,
                            'Set a screen lock before turning the lock on.',
                          );
                        }
                      },
                      child: Text(
                        'Open Security Settings',
                        style: HmType.row.copyWith(color: c.accentText),
                      ),
                    ),
                  ),
                ],
              ],
            ),
            if (on) ...[
              HmSettingsCard(
                icon: Icons.timer_outlined,
                title: 'Grace Period',
                children: [
                  for (final g in HmLockGrace.values)
                    HmChoiceTile(
                      label: g.label,
                      description: g == HmLockGrace.immediately
                          ? 'Asks again every time the app leaves the foreground.'
                          : null,
                      selected: _prefs.lockGrace == g,
                      onTap: () => unawaited(_grace(g)),
                    ),
                ],
              ),
              HmSettingsCard(
                footnote:
                    'Puts the lock back up straight away, whatever the grace period says.',
                children: [
                  HmRow(
                    icon: Icons.lock_outline,
                    label: 'Lock Now',
                    chevron: false,
                    onTap: _lock.lockNow,
                  ),
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}
