// Live Mode's words. Official wording (out/ui-text.txt, or the in-call
// screenshot shots/official-s25/live-01.png) where the official app shows
// the same state; the rest are marked.
abstract final class LiveText {
  // Official (ui-text.txt).
  static const title = 'Live Mode';
  static const end = 'End live mode';
  static const connecting = 'Connecting to your bot…';
  static const listening = 'Say something — a pause sends it.';
  static const stopped = 'Live mode stopped';
  static const micOff =
      'Microphone access is off. Enable it in Settings to use live mode.';
  static const micCouldNotOpen = "The microphone couldn't be opened.";
  static const micCouldNotRestart =
      "The microphone couldn't be restarted. Try again, or end live mode.";
  static const noVoiceApi =
      "This Hermes doesn't have the voice API yet — update it to use live mode.";
  static const reconnect = 'Reconnect before using live mode.';
  static const speechOnDevice =
      'This Hermes has no voice API yet, so speech is on device.';
  static const paused =
      'Live mode paused while Hermes Agent is in the background.';
  static const you = 'You';

  // GPT-Live (WebRTC) call (official, ui-text.txt).
  static const talkOver = 'Talk over it to interrupt';
  static const gptLiveNotConfigured = 'GPT-Live is not configured in Hermes.';
  static const gptLiveCouldNotConnect = "GPT-Live couldn't connect. Try again.";
  static const gptLiveNoConnection =
      "Couldn't create the GPT-Live audio connection.";
  static const gptLiveNoSession = 'Hermes returned no GPT-Live audio session.';
  static const gptLiveError = 'GPT-Live reported an error.';
  static const gptLiveClosed = 'GPT-Live closed';
  static const gptLiveLost = 'The GPT-Live connection was lost. Try again.';
  static const gptLiveRepliesStopped =
      'The GPT-Live connection stopped accepting replies.';

  // Official (in-call screenshot).
  static const working = 'Working…';

  // Not observed in the official app (fork wording).
  static const speaking = 'Tap the orb to interrupt';
  static const muted = 'Muted';
  static const mute = 'Mute';
  static const unmute = 'Unmute';

  // Lanes (HA-035, fork wording; Dash's lane timeline words where it has them).
  static const lanes = 'Lanes';
  static const lanesTitle = 'Lanes on this thread';
  static const lanesHint =
      'Attached lanes orbit the bot. Tap one to send it your next turn; '
      'tap the bot to talk to it again.';
  static const lanesFixture = 'Fixture lanes: answers are scripted on device.';
  static String toLane(String name) => 'Talking to $name';
  static String laneSpeaker(String name) => '$name lane';
  static String youToLane(String name) => 'You → $name';
}
