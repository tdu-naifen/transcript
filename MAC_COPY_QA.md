# Mac immutable meeting copy QA

## Fixed protocol

- Source commit: `5d61b80f84052897e476b5ff8c1c15f0648e410a`.
- [Normative contract](MAC_SYNC_PROTOCOL.md).
- [Exact shared codec](Shared/Sync/MeetingCopyWire.swift).
- Codec Git blob: `5f547011d577cdd04478ec0762db953df0634860`.
- Contract Git blob: `e0c80199efcb709071d83096cdc32b30d54c37a2`.
- Maximum raw chunk: **768 bytes**. Encrypted outer frames remain at most 4096 bytes.

This is an immutable new-meeting copy, not remote processing or bidirectional
sync. Speaker identities, voiceprints, model files, result return and deletion
propagation are not included. A green connection dot is not a copy receipt.

## Native QA entry

1. Launch the signed `TranscriptMac.app`.
2. Open **Connection** (`Command-3`).
3. Enable **Allow meeting copies from paired devices**. This is a separate,
   remembered local permission, off by default.
4. If discovery is stopped, choose **Make This Mac Discoverable**. Enabling or
   disabling receiving closes the current authenticated session so the iPhone
   must reconnect and negotiate its new capability state.
5. On the compatible iOS build, reconnect to this Mac. First pairing still
   requires matching codes and approval on both devices. A trusted reconnect
   must retain the existing pin without another code comparison.
   For a first pairing, use **Enable Pairing** on the Mac if its pairing window
   has expired or discovery was reconfigured.
6. Explicitly choose **Send** (or **Retry**) for a sealed test meeting on iPhone.
   Older UI may enter this confirmation through **Process by Mac**; the action
   must describe an immutable copy, not promise processing.
7. During transfer, the Mac iPhone icon shows activity and Connection shows byte
   progress. At 100% it still says verification/saving until the commit finishes.
8. Require **Meeting copy saved on this Mac**, then choose **Open received
   meeting**. Verify the original meeting ID/title/timestamps, transcript and
   playable audio. Only the matching durable receipt may confirm the iOS job.

Local limits are **128 MiB audio**, **16 MiB transcript**, **4 pending operations**
and **256 MiB pending bytes**. They are lower than the wire ceiling, not negotiated
limits; an oversized offer must return `failed/storage` before any `status`.
Unfinished staging expires after seven days without activity. Expiry does not
remove committed meetings/receipts or allow a cancelled operation to be replayed
as a fresh copy. Deletion tombstones cover deletions after receiver initialization.

The signed app's `Contents/Info.plist` includes
`TranscriptMeetingCopyProtocolRevision` and `TranscriptMeetingCopyChunkBytes`.
Verify them when multiple older app builds exist; the expected values are the
fixed source commit above and `768`.

No test should delete source audio, unpair a user's real device, disable the
firewall or grant biometric sharing. Test with deliberately created fixtures.
Local Network and incoming-connection firewall permissions are separate; grant
only the permissions needed for this app.

## Targeted automated entry

Use the existing XcodeGen project and XCTest runner:

```sh
xcodegen generate
xcodebuild -project Transcript.xcodeproj -scheme TranscriptMac \
  -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO \
  -only-testing:TranscriptMacTests/MacMeetingCopyInboxTests \
  -only-testing:TranscriptMacTests/MacMeetingCopySessionTests \
  -only-testing:TranscriptMacTests/MacMeetingCopyConnectionTests \
  -only-testing:TranscriptMacTests/MacBonjourServiceTests \
  -only-testing:TranscriptMacTests/MacPairingIntegrationTests \
  test
```

The receiving-permission UI test is
`TranscriptMacUITests/MacMeetingCopyUITests`.
It uses an isolated library, preferences and pairing-store service rather than
the user's normal library/pins, and does not automatically publish discovery.
App-hosted tests can interrupt another instance of this bundle: finish tests
before launching the interactive QA build.

The TCP tests exercise the production Mac receiver/controller and an independent
reference pairing client on loopback. They are not a substitute for the iOS
owner's actual sender-to-Mac acceptance run.

## Recorded Mac validation (2026-09-06)

- Fixed protocol integration: 84 targeted tests passed.
- After adding indexed collision checks: all 45 inbox/session/TCP tests passed.
- Entire Mac XCTest target: 197 tests, one opt-in real-model test skipped,
  zero failures; 16 additional Swift Testing migration tests passed.
- Native receiving-permission click/relaunch test passed; screenshot attached
  to its xcresult.
- Independent review's full-scan collision finding was fixed with Mac-local
  expression indexes. The same 5,000/100,000-row SQLite reproduction fell from
  31.86 seconds to 0.010 seconds; XCTest also verifies indexed query plans.
- Actual iOS sender-to-Mac joint acceptance remains with the iOS owner.

## Joint acceptance matrix

| Scenario | Required result |
| --- | --- |
| First copy | Exact original bytes, stable IDs, playable imported M4A, matching durable receipt |
| Interrupt after a prefix | No completed job; reconnect/offer returns verified prefix and continues exactly there |
| Restart either app | Pins retained; no automatic data send; explicit Retry resumes the same operation |
| Lose committed reply | Reoffer returns the same receipt; no second import |
| Duplicate chunk within a session | Fail closed; no overlapping write or successful duplicate ACK |
| Changed manifest/operation binding | Rejected without exposing another operation or overwriting data |
| Wrong chunk/full-asset hash | No committed receipt or published invalid meeting |
| Disk/SQLite failure | `failed/storage`, no premature confirmation; original iPhone audio retained |
| Existing meeting or known deletion | `failed/conflict`, no overwrite or resurrection |
| Replay receipt after local deletion | Historical receipt only; do not recreate deleted data |
| Disable receiving/unpair | Current session invalidated; pending work cannot continue with stale authorization |
| v1 or no TXT hint | No unsolicited capability probe/data; existing encrypted pairing/heartbeat still works |
| Oversized local offer | `failed/storage` before status/chunks, not a private protocol extension |

Inspect the Mac unified-log subsystem `com.transcript.mac`, categories
`BonjourPublishing`, `PairingSession` and `MeetingCopy`. Logs must not contain
audio, transcript payloads or pairing private keys.
