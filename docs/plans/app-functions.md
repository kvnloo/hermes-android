# Android AppFunctions test builds

This feature uses stable AndroidX AppFunctions 1.0.0 with KSP. The opt-in
build uses compile SDK 37 and AGP 9.1.1. The normal build retains compile SDK
36 and AGP 9.0.1; the Gradle wrapper and the CI Gradle pin are both 9.3.1.

Install the SDK platform `platforms;android-37.0`, then run:

```sh
ARES_APP_FUNCTIONS=true flutter build apk --debug
unzip -l build/app/outputs/flutter-apk/app-debug.apk | grep hermes_app_functions.xml
```

For a release-variant test APK, dispatch the **Release APK (z0 Agent)**
workflow with `app_functions: true` and download `z0-agent-test-app-functions`.
The input defaults to false.

An opt-in APK declares a system-bound service. KSP generates its
function schema and implementation. To test, use a device with a supported
AppFunctions caller: execute `askHermes` with a prompt and open the returned
one-shot action. It opens a draft in the current gateway, not a sent message.
Execute `runHermesRoutine` and open the returned action to reach Routines.
The user chooses a routine and explicitly taps Run now on the device. Both
paths preserve the app's existing lock/sign-in gate. These functions do not
return host results or execute background actions.

Verify the disabled/default APK has neither the generated function XML nor
the AppFunction service. Play-managed release builds continue to omit the
App Functions service and schema.
