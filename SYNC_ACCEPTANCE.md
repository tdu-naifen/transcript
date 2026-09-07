# Automatic bidirectional sync acceptance

## Release decision

**NOT accepted as usable on physical devices.** No real iPhone installation,
USB-disconnected reproduction, two-product UI transfer, or real-acoustic closed
loop was performed. The USB-related failure stage remains unconfirmed.

Implementation, component tests and physical product acceptance are separate.
Passing builds, synthetic vectors, localhost, Bonjour discovery or a worker's
report do not close the physical gates below.

Starting HEAD: `8cf3a9477c8ebf10629c55c272778d0753b8349b`; starting worktree clean.
There was no `SYNC_CONTRACT.md`. Historical entries in `agent_state.yaml` refer
to earlier checkouts/builds and are not acceptance of this branch.

Production integration commit:
**`256ee83145d74ad39096381d868baf2b879b1365`**.
Independent final review verified all 61 changed production files against the
reviewed bytes and found no remaining high-confidence code blocker. This does
not close physical-product acceptance.

## Implementation and wiring audit

| Requirement | Starting gap / change | Application integration | Acceptance |
| --- | --- | --- | --- |
| Wi-Fi without USB | TCP/Bonjour already existed; USB was not proven to carry application bytes. Added authenticated-stage/path diagnostics, retained fresh discovery and pinned recovery. | Both production pairing transports; local-network/firewall guidance remains available. | **BLOCKED:** physical failure stage and unplugged path not reproduced. |
| Mac model Settings | Processing sidebar mixed model management with work. | Settings contains ASR/diarization/embedding model controls and language-model controls; meeting views contain Process, progress, cancel, error, retry, result and Reprocess. | Model/workflow unit checks; full native interaction matrix pending. |
| Automatic processing | Manual immutable copy did not imply processing permission. | Authorized, verified automatic-audio adoption/replay enqueues persistent jobs; legacy-v2 receipts do not. Missing models wait for configuration. | Synthetic runner + real database/file tests; real-model end-to-end gate pending. |
| Bidirectional edits | Existing UUID was a v2 conflict, not an edit. | Atomic local capture, authenticated replication, UUID-only alias resolution, database-backed library/detail refresh. | Repository/channel and iOS observation tests; physical offline/restart UI gate pending. |
| Voiceprints | v2 excluded global identities and vectors. | Stable IDs, current/original names, associations, real artifact bytes, namespace-aware adoption/matching; Mac global bank and rename are wired. Unknown provenance is retained and excluded from matching. | Synthetic artifact and namespace tests only; **not real-voice acceptance**. |
| Connection entry | Redundant sidebar routes. | Mac retains the top-right connection sheet, pairing/rejection, trusted-device settings and recovery. | Source/build/logic checks; native keyboard/VoiceOver gate pending. |
| Automatic reconciliation | Explicit one-way Send/Retry only. | Independently negotiated metadata/resource protocols, committed-change observation, durable operation/byte recovery, explicit peer permissions and source-preserving relay. | Real SQLite/files and authenticated-loopback component tests; physical all-library gate pending. |
| iPhone live identity | Expanded view owned observation; collapsed model relied on later ASR/publication. | Recording model owns observation; assignment/correction/name/color do not require new ASR or a view remount. | Same-mounted-view screenshot text and separate dot-color checks with a one-second capture deadline; real inference/foreground gate pending. |

The protocol and persistence owner is [TranscriptCore/Sync](Packages/TranscriptCore/Sources/TranscriptCore/Sync).
See [ADR](SYNC_ADR.md) and [versioned contract](SYNC_CONTRACT.md).
The two `Shared/Sync/AutomaticSync*Wire.swift` files are aliases, not independent
DTO implementations. Pairing cryptography and `MeetingCopyWire.swift` are unchanged.

The automatic Mac processing job is **ASR**, not an assertion that Mac diarization
or forty-person acoustic recognition is implemented. LLM/RAG model Settings remain
available, but their UI is not represented as part of the automatic ASR job.
An analysis-resource library API/test is not a claim of automatic LLM publication.

## Data-safety repairs included

- Persistent Lamport field registers and deterministic ordering, immutable
  operation audit, per-peer acknowledgements and tombstones.
- Membership-key updates and removal of all observed tags; UUID-case compatibility
  with existing immutable copies, without display-name identity matching.
- Legacy embedded-NUL text migration and incremental, changed-column projection.
- Biometric eligibility before pagination, bilateral consent and pinned-peer-bound
  Settings actions; pause/revoke do not claim remote erasure.
- Sealed, hashed resources; durable prefix recovery, atomic final publication,
  active-prefix-aware garbage collection and restart adoption.
- Typed, version-fenced transcript publication, revision/time mappings and
  idempotent publication receipts. Stale output is not silently substituted.
- Original-audio deletion journals and removal of meeting-owned resource/processing
  copies while preserving independent references and global identities/voiceprints.

## Evidence ledger

### Post-merge cleanup

The sole Mac target remains `TranscriptMac`, built from `MacApp/` by the root
`project.yml`. The untracked alternate `mac/` project and superseded untracked
sync drafts were archived outside the repository in the evidence directory's
`cleanup-archive/`. Existing localization, package-lock and prototype-runtime WIP
was preserved in stash `ea328bdb42e678782405c9771c43d75cdacb0bc6`, not mixed into
the implementation. The earlier overlapping document WIP remains in stash
`e19ecbaa1e6fda5119b04d55fcc1ae89d6ac88c6`.

All eight retained review comments were checked against their committed fixes,
replied to with evidence and resolved. The publication/input-fence selection was
rerun with:

```sh
swift test --package-path Packages/TranscriptCore --skip-update \
  --filter 'AutomaticSyncPublicationReviewTests|AutomaticSyncProcessingInputTests'
```

Result: 12 Swift Testing tests in two suites passed, including parameterized
delivery-order, branch-arbitration, explicit-clear, coverage, alternate-supplier
and input-change cases. Evidence: `cleanup-review-regressions.log`. Existing
`postcommit-mac.log` additionally records production advertisement/retry and
worker audio-purge regressions. Physical acceptance remains blocked.

Evidence directory:
`/Users/tingzhen/.copilot/session-state/a4ab0df9-4371-44ee-be89-af180b56d832/files/`.
Final commit/build receipts are recorded below after integration; earlier passes
do not automatically certify later edits.

| Evidence | Result | Meaning / limit |
| --- | --- | --- |
| `core-integrated-migration-fixed.log` | 18 XCTest + 204 Swift Testing tests passed | Final Core CRDT, migration, provenance, recording and deletion selection. |
| `mac-final.log` / `mac-final.xcresult` | 209 tests, one explicit opt-in skip, zero failures | Signed Mac integration, model/workflow, voiceprints, legacy copy, Bonjour and pairing. |
| `ios-final.log` / `ios-final.xcresult` | 152 tests, zero failures | iOS recording, playback, search, deletion, synchronization and existing-row identity rendering. |
| `postcommit-mac.log` / `postcommit-mac.xcresult` | 30 tests, zero failures | Exact integration commit: 19 independent QA, channel, real startup/retry and input-purge fence checks. |
| `postcommit-device-build.log` | BUILD SUCCEEDED | Actual generic iOS device target, unsigned and not physically installed. |
| `build-receipts.txt` | Exact executable hashes/version receipts | Mac signed XCTest host 0.1.0 (1); iOS device build 1.0 (1). These are not installed-phone receipts. |
| `integration-production.sha256`, `integration-production-check.log` | All production hashes match | Post-commit production bytes unchanged. Reviewer digest below. |
| `ios-integrated-current.log` | 93 tests passed | Intermediate iOS library/identity/network integration; not final physical evidence. |
| `ios-frozen.log` / `ios-frozen.xcresult` | 152 tests, one failure | Playback fixture called a never-persisted meeting “Saved”; corrected to a persisted saved meeting. `ios-final` passed. |
| `mac-repaired-targets.log` / `.xcresult` | 82 tests passed | Includes 14 independent sync QA, 26 pairing, 23 processing and 11 voiceprint tests. |
| `mac-keychain-signed.log` | One real Keychain test passed | The earlier unsigned `-34018` failure is not hidden or treated as a product regression. |
| `mac-candidate.log` / `.xcresult` | 199 tests, one skip, four assertions failed | Consent/opaque-artifact counts and persisted-date fixture assumptions corrected; final Mac run passed. |
| `wireless-environment.txt` | Read-only observations | Reachable `en0`; firewall remained enabled, block-all off. Not an application's physical network path. |
| `source-freeze.sha256`, `freeze-check.log` | Source snapshot | Records review/test source; documented test-fixture changes are not silently described as identical bytes. |

The isolated existing-row capture recorded assignment **66.95 ms**, correction
**66.74 ms** and rename **66.59 ms**, each under its asserted one-second deadline.
Off-main OCR completed later and is not counted as UI propagation. Evidence:
`live-render-evidence/manifest.json`, its `render-bound-*` text attachments and
the corresponding synthetic screenshots. These are not natural inference
latencies or physical display scan-out measurements.

Failed evidence is retained: dependency-resolution/cache errors, intermediate
compiler failures, the initial one-second rendering failures, unsigned Keychain
failure, and signed-test attempts that used non-sandbox fixture directories.
Fixtures now use application-accessible temporary directories; no firewall,
sandbox entitlement or trust check was disabled to make them pass.

The unchanged baseline `nemotronIsTheOnlyTranscriptionEngine` assertion conflicts
with the already-present Apple Speech engine. It was separately reproduced and
excluded from selected validation, not “fixed” as part of this work. Actual model
tests remain opt-in; their skips do not prove model inference.

Final-review failures were not waived: discovery had omitted the automatic
capability advertisement; transcript installation could overwrite early target
edits; competing publications diverged; Unknown/uncovered intervals inherited
known identities; full processing-input fences and alternate-source receipts were
not fully wired. These were repaired and covered by independent regression tests.
The first new QA fixtures also lacked actual audio resources; they were replaced
with transferred/adopted synthetic AAC rather than weakening input fences.

### Reproduction commands

Use the existing generated project (`xcodegen generate`) and runners only.
Common Xcode flags used:

```sh
-project Transcript.xcodeproj
-clonedSourcePackagesDirPath /tmp/transcript-bidir-a4ab-packages
-disableAutomaticPackageResolution -skipPackageUpdates
-parallel-testing-enabled NO
```

Core command and exact test output are in `core-parent-final.log`. Mac commands
are recorded at the start of each Mac log; signed tests use the configured
development identity and an explicit `TRANSCRIPT_MAC_TEST_RUN_ID`. iOS commands
use scheme `TranscriptTests`, simulator
`5ABE51F3-3920-4AC6-9300-32AFBB8ED918`, and a unique `TRANSCRIPT_TEST_RUN_ID`.
No package versions or global Git configuration were changed to restore caches.
After evidence capture, the dedicated simulator and parent-owned temporary
DerivedData/package caches were removed. Reproduction therefore needs ordinary
dependency resolution or a fresh private cache. Exact app bundles are preserved
under the evidence directory's `builds/`; their executable hashes match
`build-receipts.txt`.

## Isolation deviation

The live-identity worker initially used pre-existing simulator
`A565D0B8-502B-4BA0-9704-E6D4845065BA` before processing the explicit prohibition.
Its database/keychain test namespace was isolated, but app bundles were installed
and standard preferences were read/temporarily changed. **Zero impact or zero
user-data access cannot be asserted.** Those results do not count toward final
acceptance. The disclosure is in
`.build/ios-live-observation/shared-simulator-disclosure.json`.
An enduring copy is also in `files/live-shared-simulator-disclosure.json`.

Subsequent parent execution used the dedicated simulator. The shared simulator
was not reset, cleaned or “restored” speculatively. No physical-phone installation,
trust confirmation or system-permission change was performed.

## Mandatory gates still open

| Gate | Status |
| --- | --- |
| Installed final iPhone/Mac builds, USB removed, same Wi-Fi, actual endpoint/path, discovery and trusted reconnect | **BLOCKED: requires coordinated physical-device access and permissions.** |
| Real short and large audio in both directions, playback/text equality, interrupted/terminated transfers and lost receipts through both product UIs | **NOT RUN on physical products.** Unit fixtures are not substitutes. |
| Offline identity/name/artifact changes on both devices, actual model provenance and matching, restart and deletion retention | **NOT RUN with real voices.** Synthetic-vector properties are explicitly separate. |
| iPhone save → wireless sync → real Mac model processing → published result → visible iPhone result, including reconnect/cancel/retry/stale work | **NOT RUN as a physical end-to-end loop.** |
| Natural recognition event → binding → commit → observed/rendered existing row, with inference latency separated | **NOT RUN with real audio/device lifecycle.** |
| English/Chinese, dark/light, long names, keyboard, VoiceOver and all native Settings actions | **PARTIAL:** resources/build/component rendering checked; full native interaction matrix pending. |
| Independent final integrated code review and exact build receipts | **PASS for the code commit above.** Not physical acceptance. |

Bluetooth-only and routerless peer-to-peer operation are evaluation items, not
this release gate. Existing `includePeerToPeer` use is not a Bluetooth-only
implementation or proof of routerless connectivity.

## Integration receipts

| Logical change | Local commit | Verification |
| --- | --- | --- |
| Live identity observation | `b380cf7081c29eaa59e83e2c55c4124527af0a20` | Independent live review; `ios-live-postcommit.log` passed. |
| Shared protocol/persistence | `b1b8e0b939f19960fdecc8bc7b928a703a1d28ff` | Core selection: 222 tests; CRDT, schema, resources, identity provenance and publication. |
| Authenticated transport/consent | `2151930fb1f64c6d9b8c7e0297bc988af340cb7e` | `AutomaticSync*Tests`, `MacPairingIntegrationTests`, `IOSMacPairingClientTests`, recovery tests. |
| iOS replicated-library UI/deletion | `d3470b6ad420e04391d0a818888905f755b554be` | `LibraryObservationTests`, `HomeSearchTests`, playback/deletion tests. |
| Mac Settings/automatic processing/integration | `256ee83145d74ad39096381d868baf2b879b1365` | `MacProcessingTests`, `MacLibraryTests`, model, voiceprint, pairing and copy tests. |

Requirement mapping: wireless/connection/automatic exchange use the transport and
Mac commits; model Settings and processing use the Mac commit; edits use Core,
transport and iOS-library commits; voiceprints use Core, transport and Mac commits;
live identity uses the live-observation commit. Exact test invocations are retained
at the start of the corresponding logs, including all selectors and isolation IDs.

Independent reviewer production digest:
`6f612556946f13ba51f250d09b0a0c92219a6bd6190ae8419ae80f9e8d81ea75`.

No push was performed. **The overall physical-device release gate remains blocked,
not passed.** A future coordinated run must install the chosen integration build
on both products and record those actual installation receipts.
