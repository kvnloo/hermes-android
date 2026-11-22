import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/l10n.dart';
import '../services/preview_channel.dart';

/// Opens a served build's CI page. Injectable so tests never leave the process.
typedef ServedBuildOpener = Future<void> Function(Uri url);

Future<void> _openExternally(Uri url) async {
  await launchUrl(url, mode: LaunchMode.externalApplication);
}

/// Wraps the app and, on the preview channel only, floats a small chip under
/// the status bar naming the running build, or `old → new` once CI serves a
/// newer green staging build. Tap hides it until the served build changes;
/// tap on `old → new` opens that build. Ported from Dash's ServedBuildChip.
class ServedBuildChipHost extends StatefulWidget {
  const ServedBuildChipHost({
    required this.child,
    this.channel,
    this.openBuild,
    this.pollInterval = const Duration(minutes: 5),
    super.key,
  });

  final Widget child;
  final PreviewChannel? channel;
  final ServedBuildOpener? openBuild;
  final Duration pollInterval;

  @override
  State<ServedBuildChipHost> createState() => _ServedBuildChipHostState();
}

class _ServedBuildChipHostState extends State<ServedBuildChipHost>
    with WidgetsBindingObserver {
  PreviewChannel get _channel => widget.channel ?? PreviewChannel.instance;
  Timer? _poll;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _channel.addListener(_changed);
    unawaited(_channel.load().then((_) => _channel.refresh()));
  }

  @override
  void didUpdateWidget(ServedBuildChipHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previous = oldWidget.channel ?? PreviewChannel.instance;
    if (!identical(previous, _channel)) {
      previous.removeListener(_changed);
      _channel.addListener(_changed);
      _changed();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_channel.refresh());
  }

  void _changed() {
    final preview = _channel.isPreview;
    if (preview && _poll == null) {
      _poll = Timer.periodic(
        widget.pollInterval,
        (_) => unawaited(_channel.refresh()),
      );
      _tick = Timer.periodic(const Duration(seconds: 30), (_) {
        if (mounted) setState(() {});
      });
    } else if (!preview) {
      _poll?.cancel();
      _tick?.cancel();
      _poll = null;
      _tick = null;
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _channel.removeListener(_changed);
    _poll?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final channel = _channel;
    final show = channel.loaded && channel.isPreview && !channel.hidden;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (show)
          Positioned(
            top: MediaQuery.paddingOf(context).top + 4,
            left: 0,
            right: 0,
            child: Center(
              child: _ServedBuildChip(
                channel: channel,
                openBuild: widget.openBuild ?? _openExternally,
              ),
            ),
          ),
      ],
    );
  }
}

class _ServedBuildChip extends StatelessWidget {
  const _ServedBuildChip({required this.channel, required this.openBuild});

  final PreviewChannel channel;
  final ServedBuildOpener openBuild;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final newer = channel.state == PreviewBuildState.newer;
    final served = channel.served;
    final label = channel.label(DateTime.now().toUtc());
    final background = newer ? scheme.primary : scheme.inverseSurface;
    final foreground = newer ? scheme.onPrimary : scheme.onInverseSurface;
    final l10n = context.l10n;
    return Semantics(
      container: true,
      button: true,
      label: newer
          ? l10n.preview_chip_newer(label)
          : l10n.preview_chip_running(label),
      excludeSemantics: true,
      child: Material(
        key: const Key('served-build-chip'),
        color: background.withValues(alpha: newer ? 0.95 : 0.8),
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: () {
            if (newer && served != null) {
              unawaited(openBuild(served.runUrl));
            } else {
              channel.hide();
            }
          },
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 32),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: foreground,
                  fontSize: 12,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
