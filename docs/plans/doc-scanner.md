# Document scanner: decision pending

Do not add the ML Kit scanner until the owner chooses its distribution scope.
The candidate is `com.google.android.gms:play-services-mlkit-document-scanner:16.0.0`.
Google's Android developer guide estimates about **300 KB** additional app
download, not total device usage. Google Play services fetches the scanner's
UI, models and other resources separately; first launch can wait for that
download. The app does not need its own camera permission for the ML Kit flow.
The guide lists Android API 21+ and at least 1.7 GB total device RAM. The
dependency requires working Google Play services; it is not suitable as the
only scan path for non-GMS or F-Droid users.

If approved, keep the dependency and manifest changes in a Play-specific
build path. Offer scanning only where supported, handle cancellation and
first-use download failure, and retain normal document/image attachments as a
fallback. Request only JPEG/PDF outputs actually used. Treat returned URIs as
untrusted: use the existing size/type checks, surface a preview before Send,
and clear temporary files. Compare the same signed split before and after the
change; the figure above is a vendor estimate, not a measured z0 delta.

## Non-GMS alternative

Start with Android's system photo/document picker and the existing attachment
flow. For a true scanner, add CameraX (user-granted camera permission), local
crop/rotate or optional open-source edge/perspective correction, and Android
`PdfDocument` for page assembly. Use scoped temporary files. This works
without Play services or a model download, but capture and crop UX, offline
testing, and processing/size costs become ours to maintain. Record per-ABI
download-size and offline/API-level test results before committing to it.
