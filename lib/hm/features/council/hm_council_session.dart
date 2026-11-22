import 'package:flutter/material.dart';

import '../../../core/services/dashboard_api_client.dart';
import '../../hm_ui.dart';
import 'council_reader.dart';
import 'council_run.dart';
import 'council_session.dart';
import 'hm_council.dart';

Future<void> openHmCouncilSession(
  BuildContext context, {
  required DashboardApiClient api,
  required String sessionId,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => HmCouncilSessionScreen(api: api, sessionId: sessionId),
  ),
);

/// Resolves a saved council without sending a new prompt or falling back to
/// the demo. Retrying reads the same bot and session ID again.
class HmCouncilSessionScreen extends StatefulWidget {
  const HmCouncilSessionScreen({
    super.key,
    required this.api,
    required this.sessionId,
    this.voice,
  });

  final DashboardApiClient api;
  final String sessionId;
  final CouncilVoice? voice;

  @override
  State<HmCouncilSessionScreen> createState() => _HmCouncilSessionScreenState();
}

class _HmCouncilSessionScreenState extends State<HmCouncilSessionScreen> {
  late Future<CouncilRun?> _load = _read();
  ReadAloudCouncilVoice? _ownedVoice;

  Future<CouncilRun?> _read() =>
      loadCouncilSession(widget.api, widget.sessionId);

  @override
  void dispose() {
    _ownedVoice?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<CouncilRun?>(
    future: _load,
    builder: (context, snapshot) {
      final run = snapshot.data;
      if (run != null) {
        return HmCouncilScreen(
          source: CouncilSource(
            run: run,
            live: true,
            sessionId: widget.sessionId,
          ),
          voice: widget.voice ?? (_ownedVoice ??= ReadAloudCouncilVoice()),
        );
      }

      final loading = snapshot.connectionState != ConnectionState.done;
      final error = snapshot.error;
      final message = switch (error) {
        FormatException() ||
        CouncilParseError() => 'This council snapshot could not be read.',
        null => 'No council snapshot has been saved yet.',
        _ => 'Could not load this council.',
      };
      return Scaffold(
        body: Column(
          children: [
            const HmTopBar(leading: HmBackButton(), title: 'Council'),
            Expanded(
              child: Center(
                child: loading
                    ? const CircularProgressIndicator(
                        semanticsLabel: 'Loading council',
                      )
                    : Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(message, textAlign: TextAlign.center),
                            TextButton(
                              onPressed: () {
                                final next = _read();
                                setState(() {
                                  _load = next;
                                });
                              },
                              child: const Text('Retry'),
                            ),
                          ],
                        ),
                      ),
              ),
            ),
          ],
        ),
      );
    },
  );
}
