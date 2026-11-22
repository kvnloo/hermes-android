import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Which builds this install follows.
///
/// [stable] is the normal release path. [preview] is the dogfood path: the
/// newest green `staging` build from the fork's CI, the same build the S25
/// auto-updater installs. Ported from Dash's turbo preview channel and its
/// served-build chip; Flutter has no Metro, so "served" means "newest green
/// staging build" instead of "bundle a dev server serves".
enum UpdateChannel { stable, preview }

/// The identity of the code running in this process.
///
/// CI sets it with `--dart-define=HERMES_BUILD_SHA=<sha>` and
/// `--dart-define=HERMES_BUILD_TIME=<unix seconds | unix ms | ISO-8601>`.
/// A local or upstream build has neither and reports `sha == null`.
@immutable
class RunningBuild {
  const RunningBuild({this.sha, this.builtAt});

  final String? sha;
  final DateTime? builtAt;

  static const _envSha = String.fromEnvironment('HERMES_BUILD_SHA');
  static const _envTime = String.fromEnvironment('HERMES_BUILD_TIME');

  /// What this binary was built from.
  static final RunningBuild current = parse(_envSha, _envTime);

  /// Parse build-time values without treating absent metadata as a fresh build.
  static RunningBuild parse(String? shaValue, String? timeValue) =>
      RunningBuild(sha: parseSha(shaValue), builtAt: parseBuildTime(timeValue));
}

final _shaPattern = RegExp(r'^[0-9a-f]{7,64}$');

/// A lower-case hex commit id, or null.
String? parseSha(String? value) {
  final candidate = value?.trim().toLowerCase() ?? '';
  return _shaPattern.hasMatch(candidate) ? candidate : null;
}

/// Unix seconds, unix milliseconds or an ISO-8601 instant with a zone; else null.
DateTime? parseBuildTime(String? value) {
  final raw = value?.trim() ?? '';
  DateTime? parsed;
  if (RegExp(r'^\d{10}$').hasMatch(raw)) {
    parsed = DateTime.fromMillisecondsSinceEpoch(
      int.parse(raw) * 1000,
      isUtc: true,
    );
  } else if (RegExp(r'^\d{13}$').hasMatch(raw)) {
    parsed = DateTime.fromMillisecondsSinceEpoch(int.parse(raw), isUtc: true);
  } else if (RegExp(
    r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$',
    caseSensitive: false,
  ).hasMatch(raw)) {
    parsed = DateTime.tryParse(raw)?.toUtc();
  }
  return parsed != null && parsed.millisecondsSinceEpoch > 0 ? parsed : null;
}

/// The newest green preview build CI has published.
@immutable
class ServedBuild {
  const ServedBuild({
    required this.sha,
    required this.runNumber,
    required this.builtAt,
    required this.runUrl,
  });

  final String sha;
  final int runNumber;
  final DateTime? builtAt;
  final Uri runUrl;

  @override
  bool operator ==(Object other) =>
      other is ServedBuild &&
      other.sha == sha &&
      other.runNumber == runNumber &&
      other.builtAt == builtAt &&
      other.runUrl == runUrl;

  @override
  int get hashCode => Object.hash(sha, runNumber, builtAt, runUrl);
}

/// Where the preview channel reads from. Public GitHub API, no credentials.
class PreviewChannelSource {
  static const owner = 'kvnloo';
  static const repo = 'hermes-android';
  static const workflow = 'play.yml';
  static const branch = 'staging';

  static Uri get runsUri => Uri.https(
    'api.github.com',
    '/repos/$owner/$repo/actions/workflows/$workflow/runs',
    {'branch': branch, 'status': 'success', 'per_page': '1'},
  );
}

/// The first green staging run in a GitHub workflow-runs payload, or null.
///
/// Everything is validated: a run on another branch, an unfinished run, a
/// malformed SHA or a link off the fork's own Actions page is ignored.
ServedBuild? parseServedBuild(String body) {
  Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (_) {
    return null;
  }
  if (decoded is! Map<String, dynamic>) return null;
  final runs = decoded['workflow_runs'];
  if (runs is! List) return null;
  for (final run in runs) {
    if (run is! Map<String, dynamic>) continue;
    if (run['head_branch'] != PreviewChannelSource.branch ||
        run['status'] != 'completed' ||
        run['conclusion'] != 'success') {
      continue;
    }
    final sha = run['head_sha'];
    final number = run['run_number'];
    final rawUrl = run['html_url'];
    if (sha is! String || parseSha(sha) == null || sha.length != 40) continue;
    if (number is! int || number <= 0 || rawUrl is! String) continue;
    final url = Uri.tryParse(rawUrl);
    if (url == null ||
        url.scheme != 'https' ||
        url.host != 'github.com' ||
        url.hasPort ||
        url.userInfo.isNotEmpty ||
        url.hasQuery ||
        url.hasFragment ||
        url.pathSegments.length != 5 ||
        url.pathSegments[0] != PreviewChannelSource.owner ||
        url.pathSegments[1] != PreviewChannelSource.repo ||
        url.pathSegments[2] != 'actions' ||
        url.pathSegments[3] != 'runs' ||
        !RegExp(r'^\d+$').hasMatch(url.pathSegments[4])) {
      continue;
    }
    final at = run['updated_at'];
    return ServedBuild(
      sha: sha.toLowerCase(),
      runNumber: number,
      builtAt: at is String ? DateTime.tryParse(at)?.toUtc() : null,
      runUrl: url,
    );
  }
  return null;
}

String shortSha(String? sha) => sha == null ? '?' : sha.substring(0, 7);

/// `just served`, `3m old`, `2h old`, `4d old`; Dash's wording.
String servedAgeLabel(DateTime? at, DateTime now) {
  if (at == null) return 'age unknown';
  final age = now.difference(at);
  if (age < const Duration(minutes: -1)) return 'clock skew';
  if (age < const Duration(minutes: 1)) return 'just served';
  if (age < const Duration(hours: 1)) return '${age.inMinutes}m old';
  if (age < const Duration(days: 1)) return '${age.inHours}h old';
  return '${age.inDays}d old';
}

/// How the running build relates to the served one.
enum PreviewBuildState {
  /// Nothing has been read from CI yet.
  checking,

  /// CI could not be read and nothing was cached.
  unreachable,

  /// This binary carries no SHA, so it cannot be compared.
  unknown,

  /// Running the served build.
  current,

  /// CI serves a different, newer green build.
  newer,
}

PreviewBuildState previewBuildState({
  required RunningBuild running,
  required ServedBuild? served,
  required bool fetchFailed,
}) {
  if (served == null) {
    return fetchFailed
        ? PreviewBuildState.unreachable
        : PreviewBuildState.checking;
  }
  if (running.sha == null) return PreviewBuildState.unknown;
  return served.sha.startsWith(running.sha!) ||
          running.sha!.startsWith(served.sha)
      ? PreviewBuildState.current
      : PreviewBuildState.newer;
}

/// One line for the chip: `abc1234 · 3m old`, or `abc1234 → def5678` once CI
/// serves something newer, as in Dash's `liveChipLabel`.
String previewChipLabel({
  required RunningBuild running,
  required ServedBuild? served,
  required PreviewBuildState state,
  required DateTime now,
}) {
  switch (state) {
    case PreviewBuildState.checking:
      return '${shortSha(running.sha)} · checking';
    case PreviewBuildState.unreachable:
      return '${shortSha(running.sha)} · served ?';
    case PreviewBuildState.unknown:
      return 'served ${shortSha(served!.sha)} · '
          '${servedAgeLabel(served.builtAt, now)}';
    case PreviewBuildState.current:
      return '${shortSha(running.sha)} · '
          '${servedAgeLabel(running.builtAt ?? served!.builtAt, now)}';
    case PreviewBuildState.newer:
      return '${shortSha(running.sha)} → ${shortSha(served!.sha)}';
  }
}

/// The app-wide preview channel: the chosen channel, plus the newest served
/// build while that channel is [UpdateChannel.preview].
///
/// Every network failure is swallowed into [fetchFailed]; the chip is
/// advisory and must never break a launch.
class PreviewChannel extends ChangeNotifier {
  PreviewChannel({
    http.Client? client,
    SharedPreferences? preferences,
    RunningBuild? running,
    DateTime Function()? clock,
  }) : running = running ?? RunningBuild.current,
       _clock = clock ?? DateTime.now {
    _client = client;
    _preferences = preferences;
  }

  static final PreviewChannel instance = PreviewChannel();

  static const channelKey = 'update_channel_v1';
  static const servedKey = 'preview_served_build_v1';

  /// Unauthenticated GitHub budget is per IP; a fetch per minute is plenty.
  static const minFetchInterval = Duration(minutes: 1);
  static const requestTimeout = Duration(seconds: 10);

  final RunningBuild running;
  final DateTime Function() _clock;
  http.Client? _client;
  SharedPreferences? _preferences;

  UpdateChannel _channel = UpdateChannel.stable;
  ServedBuild? _served;
  bool _fetchFailed = false;
  bool _loaded = false;
  DateTime? _lastFetch;
  Future<void>? _inFlight;
  String? _hiddenFor;

  UpdateChannel get channel => _channel;
  bool get isPreview => _channel == UpdateChannel.preview;
  ServedBuild? get served => _served;
  bool get fetchFailed => _fetchFailed;
  bool get loaded => _loaded;

  PreviewBuildState get state => previewBuildState(
    running: running,
    served: _served,
    fetchFailed: _fetchFailed,
  );

  String label(DateTime now) => previewChipLabel(
    running: running,
    served: _served,
    state: state,
    now: now,
  );

  String get _key => '${running.sha}:${_served?.sha}';

  /// Hidden until the served build changes, as Dash's chip does on tap.
  bool get hidden => _hiddenFor == _key && state != PreviewBuildState.newer;

  /// Forget loaded state so a test can start from fresh preferences.
  @visibleForTesting
  void debugReset({http.Client? client, SharedPreferences? preferences}) {
    _client = client;
    _preferences = preferences;
    _channel = UpdateChannel.stable;
    _served = null;
    _fetchFailed = false;
    _loaded = false;
    _lastFetch = null;
    _inFlight = null;
    _hiddenFor = null;
  }

  void hide() {
    _hiddenFor = _key;
    notifyListeners();
  }

  http.Client get _http => _client ??= http.Client();

  Future<SharedPreferences> get _prefs async =>
      _preferences ??= await SharedPreferences.getInstance();

  /// Reads the stored channel and the last served build. Safe to call often.
  Future<void> load() async {
    if (_loaded) return;
    final preferences = await _prefs;
    _channel = preferences.getString(channelKey) == UpdateChannel.preview.name
        ? UpdateChannel.preview
        : UpdateChannel.stable;
    final cached = preferences.getString(servedKey);
    if (cached != null) _served = parseServedBuild(cached);
    _loaded = true;
    notifyListeners();
  }

  Future<void> setChannel(UpdateChannel channel) async {
    await load();
    final preferences = await _prefs;
    await preferences.setString(channelKey, channel.name);
    if (_channel == channel) return;
    _channel = channel;
    _hiddenFor = null;
    notifyListeners();
    if (channel == UpdateChannel.preview) await refresh(force: true);
  }

  /// Fetches the newest green staging run unless one was fetched recently.
  Future<void> refresh({bool force = false}) async {
    await load();
    if (!isPreview) return;
    final last = _lastFetch;
    if (!force &&
        last != null &&
        _clock().difference(last) < minFetchInterval) {
      return;
    }
    return _inFlight ??= _fetch().whenComplete(() => _inFlight = null);
  }

  Future<void> _fetch() async {
    _lastFetch = _clock();
    try {
      final response = await _http
          .get(
            PreviewChannelSource.runsUri,
            headers: const {
              'Accept': 'application/vnd.github+json',
              'User-Agent': 'hermes-android',
            },
          )
          .timeout(requestTimeout);
      final build = response.statusCode == 200
          ? parseServedBuild(response.body)
          : null;
      if (build == null) {
        _fetchFailed = true;
      } else {
        _fetchFailed = false;
        _served = build;
        await (await _prefs).setString(servedKey, response.body);
      }
    } catch (_) {
      _fetchFailed = true;
    }
    notifyListeners();
  }
}
