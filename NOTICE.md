# Attribution and status

This community edition is an independent fork of Ares (MIT), originally
Hermes Android by Sam Russell and contributors. The fork is not affiliated
with Nous Research and is not an official Hermes Agent or Ares release.

The upstream snapshot used for the Remote Gateway work lacked a canonical
licence file, but its README already declared the application MIT-licensed.
The root [LICENSE](LICENSE) records those existing application terms in full;
it does not relicense third-party code or assets. Copyright and other rights
remain with their respective authors. Source history and contributor
attribution are preserved.

The bundled Cinzel font retains its [SIL Open Font License 1.1](assets/fonts/OFL.txt).
The embedded FCM distributor retains its upstream LGPL-2.1-or-later terms; see
the [Library notice](third_party/embedded-push-notice.md),
[verbatim licence](third_party/licenses/embedded-fcm-distributor-LGPL-2.1.txt)
and [source/relink instructions](third_party/embedded-push-relink.md).
The [source manifest](third_party/sources/embedded-fcm-distributor-3.1.0/manifest.json)
identifies the exact retained upstream archive, source JAR and POM. The
archive travels in the APK's Android assets with an extra .bin suffix and
also accompanies the matching application source in the source/relink ZIP.
The local AAR substitution path is documented in the relink instructions.

See the [third-party inventory](third_party/NOTICE.md) for copied source/build
materials, fonts and avatars, the [Android TTS patch](third_party/flutter_tts_android/README.md)
and the [native wake engine and model](third_party/voice/NOTICE.md). Local
notices appear in Settings > About > Licences alongside Flutter's generated
package notices. The Flutter list is not an inventory of resolved Android
Maven artifacts; those dependencies retain their own terms and notices.

Synthetic fixture credentials are test data only. No private gateway
credentials, release signing keys, device profiles, or operator logs are part
of the public source tree.
