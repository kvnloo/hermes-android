# Device tools v1 (proposed host contract)

The Android tool dispatcher is local only. Hosts must not advertise these
tools yet: the current gateway does not negotiate or dispatch device calls.
Granting a system permission or turning a source on never sends data off-device.

A future gateway implementation should negotiate `device_tools_v1` on the
authenticated NextGen socket, then submit a server-to-client request:

```json
{"jsonrpc":"2.0","id":"device-call-1","method":"device.tool.call","params":{"session_id":"active-session","tool":"device.health.steps","args":{}}}
```

Require a known runtime session on that exact gateway and an unlocked,
foreground app. Show the destination, operation and arguments in a
per-request prompt; do not call the local dispatcher without approval.
Return results only to the requesting socket/session; never retry an alarm or
a rejected/cancelled prompt on reconnection. Reject oversized or unknown
arguments. Use one in-flight prompt per client, time-bound it, and do not log
arguments or results. Do not expose these operations via Android intents.

| Tool | JSON args | Successful `data` |
| --- | --- | --- |
| `device.health.steps` | `{}` | `{"steps":1200}`, aggregate last 24 hours, `null` if no records |
| `device.calendar.events` | `{"startMs":1760000000000,"endMs":1760003600000}` | `{"events":[{"title":"Meeting","startMs":1760000000000,"endMs":1760003600000}]}`, max 25 device-calendar occurrences, no body/attendees/links; start between now−7 and now+28 days, span no more than 7 days |
| `device.contacts.find` | `{"name":"Alex"}` | `{"names":["Alex"]}`, 2–80 character query, max 10 display names, no contact details |
| `device.location.approximate` | `{}` | `{"latitude":12.34,"longitude":45.67,"timeMs":1760000000000}`, cached approximate network fix no older than five minutes, no background location |
| `device.alarm.set` | `{"atMs":1760000000000}` | `{"atMs":1760000000000}`, 10 seconds–7 days ahead, replaces the prior app device alarm, local notification only; turning the source off cancels it |

Timestamps are integer Unix milliseconds in UTC. Successful JSON-RPC `result`
is `{"ok":true,"data":{...}}`. Failure `result` is
`{"ok":false,"error":{"code":"permission_denied"}}`. Local errors:
`disabled` (source off), `permission_denied` (missing or revoked OS grant),
`unavailable` (unsupported provider or missing fresh fix), and
`invalid_arguments`. The future adapter must also support `user_denied`,
`cancelled`, `busy`, and `not_foreground`. None include sensitive data.

Settings → Device access manages five independent sources, all off by default.
Health Connect uses the Android 14+ platform service and read-only step permission; the legacy standalone provider is unsupported. Contacts/calendar use Android
read permission; location is coarse only. Exact alarms require Android's
special access on Android 12+ and notification permission on Android 13+.
An unavailable Health Connect provider leaves the source unavailable.
Before any Play release, review Health Connect and exact alarm declarations
and verify restrictions with a real device.
