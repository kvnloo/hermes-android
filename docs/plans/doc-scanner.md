# Android document scanner

The Android app uses the stable
`com.google.android.gms:play-services-mlkit-document-scanner:16.0.0`
([Google's integration guide](https://developers.google.com/ml-kit/vision/doc-scanner/android),
[ML Kit release notes](https://developers.google.com/ml-kit/release-notes)).
A small Kotlin channel launches the Google-owned scanner only after the user
chooses **Scan document**. Gallery import and full scanner editing are enabled.
NextGen and Remote Gateway allow up to five pages and stage a combined PDF plus
one JPEG per page. The PDF is staged first so it represents the whole scan even
if the draft has few slots left. Legacy REST remains single-image: it scans one
page and only stages the JPEG, using the usual REST size limit.

The scan flow requests no new app runtime permission. Play services owns
the camera and gallery flow. The channel copies the returned files to private cache off the
main thread, bounded to 16 MiB per source. Drafts use the existing file and
sanitized-image preparation, count and size checks; source copies are deleted
after staging. Cancellation preserves the draft, and the app does not upload
the scan until Send. Normal file/image pickers remain available.

## Compatibility and size

- Requires working Google Play services and approximately 1.7 GB of RAM.
  The app minimum stays at API 24 (the scanner AAR declares API 23). The option
  is omitted on unsupported devices; a module response of unsupported also
  hides it for the rest of that activity.
- The first scan may download scanner UI and models from Play services. A
  temporary initialization failure shows a retry message instead of disabling
  the first-use path. Test this both online and offline.
- The Gradle dependency is included in Android APKs, even though the scanner
  is hidden without Play services. Runtime hiding does not make that artifact
  Play-free; review F-Droid eligibility separately before distribution.
- Universal debug APK (`flutter build apk --debug`, Flutter 3.44.0):
  staging **332,286,069 bytes**, scanner **333,048,090 bytes**,
  delta **+762,021 bytes** (0.73 MiB, 0.23%).
  This measures the feature and its dependencies together, not Play Store
  download size. Google estimates about **300 KB** of extra app download size;
  Play services downloads the scanner module separately.

## S25 verification

1. Install the debug APK on an S25 with current Google Play services. Use an
   online NextGen or Remote Gateway chat and a blank/sample document.
2. Tap the composer paperclip. Screenshot the **Scan document** entry
   (suggested name: `s25-scan-menu.png`).
3. Tap it and allow the Play services flow to initialize. Capture a page, then
   use gallery import to add another. Check page order and take a scanner
   screenshot (`s25-scan-flow.png`). Do not use real personal documents.
4. Confirm the scan. Screenshot the draft with the PDF and both JPEG
   attachments before sending (`s25-scan-draft.png`). Remove one JPEG and
   verify the other drafts stay. If testing delivery, send only to a test
   gateway and open the delivered PDF to confirm it contains both pages.
5. Reopen the scanner and back out. Verify existing text and attachments
   are unchanged. Repeat on a REST-only chat and verify only one JPEG is
   staged. On a non-GMS device or AOSP image, verify the scanner entry is
   absent but the normal attachment actions still work.
6. With a fresh scanner module and no network, verify that a failed launch
   returns to the draft and shows the retry message. Reconnect and retry.

## Non-GMS alternative

Start with Android's system photo/document picker and the existing attachment
flow. For a true scanner, add CameraX (user-granted camera permission), local
crop/rotate or optional open-source edge/perspective correction, and Android
`PdfDocument` for page assembly. Use scoped temporary files. This works
without Play services or a model download, but capture and crop UX, offline
testing, and processing/size costs become ours to maintain. Record per-ABI
download-size and offline/API-level test results before committing to it.
