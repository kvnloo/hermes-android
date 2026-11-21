// App lock: the device owner proves who they are (biometrics, with the
// device screen lock as fallback) before Hermes shows anything. [HmLockGate]
// covers the whole app when the lock is up; [HmAppLock] decides when that
// is: on launch, and on return after the grace period.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../nextgen/theme/nextgen_theme.dart';
import '../../hm_ui.dart';
import 'settings_prefs.dart';

/// What this device can use to unlock.
enum HmLockSupport {
  /// Biometrics or a screen lock are set up; [HmLockCapability.face] says
  /// whether face is the biometric.
  available,

  /// No screen lock and no biometrics.
  none,
}

@immutable
class HmLockCapability {
  const HmLockCapability(this.support, {this.face = false});
  final HmLockSupport support;
  final bool face;

  bool get available => support == HmLockSupport.available;

  /// The method the switch names: "Require Face Unlock" / "Require Screen
  /// Lock".
  String get method => face ? 'Face Unlock' : 'Screen Lock';
}

/// The outcome of one prompt.
enum HmAuthResult {
  success,

  /// Dismissed or failed without side effects.
  canceled,

  /// Too many attempts.
  lockedOut,

  /// No screen lock or biometrics.
  noCredentials,

  /// The prompt could not be shown.
  unavailable,
}

/// The message a failed prompt shows, in the official wording.
String? hmAuthMessage(HmAuthResult r) => switch (r) {
  HmAuthResult.success || HmAuthResult.canceled => null,
  HmAuthResult.lockedOut =>
    'Too many attempts. Use the device screen lock to continue.',
  HmAuthResult.noCredentials => 'Set a screen lock before turning the lock on.',
  HmAuthResult.unavailable => 'Biometrics are not available on this device.',
};

/// The platform prompt, behind an interface so tests can fake it.
abstract class HmAuthenticator {
  Future<HmLockCapability> capability();
  Future<HmAuthResult> authenticate(String reason);
}

class HmLocalAuthenticator implements HmAuthenticator {
  HmLocalAuthenticator([LocalAuthentication? auth])
    : _auth = auth ?? LocalAuthentication();
  final LocalAuthentication _auth;

  @override
  Future<HmLockCapability> capability() async {
    try {
      if (!await _auth.isDeviceSupported()) {
        return const HmLockCapability(HmLockSupport.none);
      }
      final kinds = await _auth.getAvailableBiometrics();
      final face =
          kinds.contains(BiometricType.face) &&
          !kinds.contains(BiometricType.fingerprint);
      return HmLockCapability(HmLockSupport.available, face: face);
    } on PlatformException {
      return const HmLockCapability(HmLockSupport.none);
    } on MissingPluginException {
      return const HmLockCapability(HmLockSupport.none);
    }
  }

  @override
  Future<HmAuthResult> authenticate(String reason) async {
    try {
      final ok = await _auth.authenticate(
        localizedReason: reason,
        persistAcrossBackgrounding: true,
      );
      return ok ? HmAuthResult.success : HmAuthResult.canceled;
    } on LocalAuthException catch (e) {
      return switch (e.code) {
        LocalAuthExceptionCode.temporaryLockout ||
        LocalAuthExceptionCode.biometricLockout => HmAuthResult.lockedOut,
        LocalAuthExceptionCode.noCredentialsSet => HmAuthResult.noCredentials,
        LocalAuthExceptionCode.userCanceled ||
        LocalAuthExceptionCode.systemCanceled ||
        LocalAuthExceptionCode.timeout ||
        LocalAuthExceptionCode.authInProgress => HmAuthResult.canceled,
        _ => HmAuthResult.unavailable,
      };
    } on PlatformException {
      return HmAuthResult.unavailable;
    } on MissingPluginException {
      return HmAuthResult.unavailable;
    }
  }
}

/// Opens Android's security settings (screen lock, biometrics). Returns
/// false when the host activity doesn't answer the channel.
typedef HmOpenSecuritySettings = Future<bool> Function();

const hmSecurityChannel = MethodChannel(
  'com.hermesagent.hermes_android/security',
);

Future<bool> hmOpenAndroidSecuritySettings() async {
  try {
    return await hmSecurityChannel.invokeMethod<bool>(
          'openSecuritySettings',
        ) ??
        false;
  } on MissingPluginException {
    return false;
  } on PlatformException {
    return false;
  }
}

/// When the lock is up. Reads [HmSettingsPrefs] for on/off and the grace
/// period.
class HmAppLock extends ChangeNotifier {
  HmAppLock({
    HmSettingsPrefs? prefs,
    HmAuthenticator? authenticator,
    DateTime Function()? clock,
  }) : prefs = prefs ?? HmSettingsPrefs.instance,
       authenticator = authenticator ?? HmLocalAuthenticator(),
       _clock = clock ?? DateTime.now;

  /// The app's lock. Tests swap its [authenticator].
  static final HmAppLock instance = HmAppLock();

  final HmSettingsPrefs prefs;
  HmAuthenticator authenticator;
  final DateTime Function() _clock;

  bool _locked = false;
  bool _started = false;
  bool _authenticating = false;
  DateTime? _leftAt;
  String? message;

  bool get locked => _locked;
  bool get authenticating => _authenticating;

  /// Puts the lock up on launch when it's on. Runs once.
  void start() {
    if (_started) return;
    _started = true;
    if (prefs.lockEnabled) _setLocked(true);
  }

  /// The app left the foreground.
  void left() {
    // The system prompt itself backgrounds the activity on some devices.
    if (_authenticating || _locked) return;
    _leftAt = _clock();
    // Immediately: cover now, so the app switcher shows nothing.
    if (prefs.lockEnabled && prefs.lockGrace == HmLockGrace.immediately) {
      _setLocked(true);
    }
  }

  /// The app came back to the foreground.
  void returned() {
    final at = _leftAt;
    _leftAt = null;
    if (!prefs.lockEnabled || _locked || at == null) return;
    if (_clock().difference(at) >= prefs.lockGrace.duration) _setLocked(true);
  }

  /// Puts the lock back up straight away, whatever the grace period says.
  void lockNow() {
    if (prefs.lockEnabled) _setLocked(true);
  }

  /// Shows the system prompt; lowers the lock on success.
  Future<HmAuthResult> unlock() async {
    if (_authenticating) return HmAuthResult.canceled;
    _authenticating = true;
    message = null;
    notifyListeners();
    HmAuthResult result;
    try {
      result = await authenticator.authenticate('Unlock Hermes Agent.');
    } finally {
      _authenticating = false;
    }
    if (result == HmAuthResult.success) {
      _locked = false;
    } else {
      message = hmAuthMessage(result);
    }
    notifyListeners();
    return result;
  }

  /// Turning the lock on or off asks the owner first.
  Future<HmAuthResult> confirmChange(bool turnOn) async {
    _authenticating = true;
    try {
      return await authenticator.authenticate(
        turnOn
            ? 'Turn on the lock for Hermes Agent.'
            : 'Turn off the lock for Hermes Agent.',
      );
    } finally {
      _authenticating = false;
    }
  }

  void _setLocked(bool v) {
    if (_locked == v) return;
    _locked = v;
    message = null;
    notifyListeners();
  }
}

/// Covers [child] with the lock screen while [HmAppLock.locked].
class HmLockGate extends StatefulWidget {
  const HmLockGate({super.key, required this.child, this.prefs, this.lock});

  final Widget child;

  /// Loads [HmSettingsPrefs] if nothing has yet.
  final SharedPreferences? prefs;
  final HmAppLock? lock;

  @override
  State<HmLockGate> createState() => _HmLockGateState();
}

class _HmLockGateState extends State<HmLockGate> with WidgetsBindingObserver {
  late final HmAppLock _lock = widget.lock ?? HmAppLock.instance;
  bool _prompted = false;

  @override
  void initState() {
    super.initState();
    final p = widget.prefs;
    if (p != null) _lock.prefs.ensureLoaded(p);
    WidgetsBinding.instance.addObserver(this);
    _lock.addListener(_changed);
    _lock.start();
    _maybePrompt();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _lock.removeListener(_changed);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        _prompted = false;
        _lock.left();
      case AppLifecycleState.resumed:
        _lock.returned();
        _maybePrompt();
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    if (!_lock.locked) _prompted = false;
  }

  /// Asks once each time the lock goes up while the app is in front.
  void _maybePrompt() {
    if (!_lock.locked || _prompted) return;
    final state = WidgetsBinding.instance.lifecycleState;
    if (state != null && state != AppLifecycleState.resumed) return;
    _prompted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _lock.locked) unawaited(_lock.unlock());
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_lock.locked) _maybePrompt();
    return Stack(
      fit: StackFit.expand,
      children: [
        // Kept mounted so state survives; hidden from sight and touch.
        Offstage(offstage: _lock.locked, child: widget.child),
        if (_lock.locked) HmLockScreen(lock: _lock),
      ],
    );
  }
}

/// What shows while locked.
class HmLockScreen extends StatelessWidget {
  const HmLockScreen({super.key, required this.lock});
  final HmAppLock lock;

  @override
  Widget build(BuildContext context) {
    final c = NgColors.of(context);
    return Material(
      color: c.background,
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lock_outline, size: 56, color: c.text2),
                const SizedBox(height: 20),
                Text(
                  'Unlock Hermes Agent.',
                  textAlign: TextAlign.center,
                  style: HmType.display.copyWith(color: c.text),
                ),
                if (lock.message != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    lock.message!,
                    textAlign: TextAlign.center,
                    style: HmType.value.copyWith(color: c.danger),
                  ),
                ],
                const SizedBox(height: 28),
                // No Tooltip: the gate sits above the Navigator's Overlay.
                Semantics(
                  button: true,
                  label: 'Unlock Hermes Agent.',
                  excludeSemantics: true,
                  child: SizedBox.square(
                    dimension: 64,
                    child: Material(
                      color: c.accentSoft,
                      shape: const CircleBorder(),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        key: const ValueKey('hm-unlock'),
                        onTap: lock.authenticating
                            ? null
                            : () => unawaited(lock.unlock()),
                        child: Icon(
                          Icons.fingerprint,
                          size: 32,
                          color: c.accentText,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
