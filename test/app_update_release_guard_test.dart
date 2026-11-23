import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/app_update_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _release(String owner) =>
    '{"tag_name":"v9.9.9","html_url":"https://github.com/$owner/hermes-android/releases/tag/v9.9.9",'
    '"draft":false,"prerelease":false,"assets":[{"name":"app-arm64-v8a-release.apk",'
    '"browser_download_url":"https://github.com/$owner/hermes-android/releases/download/v9.9.9/app-arm64-v8a-release.apk",'
    '"digest":"sha256:${'a' * 64}","size":1234,"state":"uploaded"}]}';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('release repository', () {
    test('the updater follows kvnloo/hermes-android', () {
      expect(appReleaseRepository.owner, 'kvnloo');
      expect(appReleaseRepository.name, 'hermes-android');
      expect(
        AppUpdateService.releasesApiUrl,
        'https://api.github.com/repos/kvnloo/hermes-android/releases/latest',
      );
    });

    test('APK assets from the upstream fork are never offered', () {
      final own = AppUpdateService.parseRelease(_release('kvnloo'))!;
      expect(own.apkForAbis(['arm64-v8a']), isNotNull);
      final upstream = AppUpdateService.parseRelease(_release('rusty4444'))!;
      expect(upstream.apkAssets, isEmpty);
    });
  });

  group('Play installer', () {
    test('recognises only the Play Store installer', () {
      expect(isPlayStoreInstaller('com.android.vending'), isTrue);
      expect(isPlayStoreInstaller(null), isFalse);
      expect(
        isPlayStoreInstaller('com.google.android.packageinstaller'),
        isFalse,
      );
      expect(isPlayStoreInstaller('org.fdroid.fdroid'), isFalse);
    });

    test('a Play-installed build never checks GitHub', () async {
      var requests = 0;
      final service = AppUpdateService(
        installerPackage: () async => 'com.android.vending',
        client: MockClient((request) async {
          requests++;
          return http.Response(_release('kvnloo'), 200);
        }),
      );
      expect(await service.playManagesUpdates(), isTrue);
      final result = await service.checkForUpdate(
        currentVersion: '1.0.0',
        force: true,
      );
      expect(result.hasUpdate, isFalse);
      expect(result.outcome, AppUpdateOutcome.failed);
      expect(
        await service.launchPromptRelease(currentVersion: '1.0.0'),
        isNull,
      );
      expect(requests, 0);
    });

    test('a sideloaded build still checks GitHub', () async {
      var requests = 0;
      final service = AppUpdateService(
        installerPackage: () async => 'com.google.android.packageinstaller',
        client: MockClient((request) async {
          requests++;
          expect(
            request.url.path,
            '/repos/kvnloo/hermes-android/releases/latest',
          );
          return http.Response(_release('kvnloo'), 200);
        }),
      );
      expect(await service.playManagesUpdates(), isFalse);
      final result = await service.checkForUpdate(
        currentVersion: '1.0.0',
        force: true,
      );
      expect(result.outcome, AppUpdateOutcome.updateAvailable);
      expect(requests, 1);
    });

    test('an installer lookup failure keeps the sideload path', () async {
      final service = AppUpdateService(
        installerPackage: () async => throw StateError('no channel'),
        client: MockClient(
          (request) async => http.Response(_release('kvnloo'), 200),
        ),
      );
      expect(await service.playManagesUpdates(), isFalse);
      final result = await service.checkForUpdate(
        currentVersion: '1.0.0',
        force: true,
      );
      expect(result.outcome, AppUpdateOutcome.updateAvailable);
    });
  });
}
