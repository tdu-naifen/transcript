# Automatic sync contract — version 1

Normative implementation: `Packages/TranscriptCore/Sources/TranscriptCore/Sync/`
contains `AutomaticSyncWire.swift`, `AutomaticSyncResourceWire.swift` and
`AutomaticSyncRepository.swift`. Both codecs are compiled once by TranscriptCore;
the similarly named Shared files are optional import/typealias bridges, not
copied DTO definitions or required app target sources. Apps use `import TranscriptCore`.
Independent of immutable
meeting-copy v2. Capability `automaticSync.v1`, encrypted application message
type `automaticSync.v1`; never change the existing authentication handshake,
counter allocation or 4096-byte encrypted frame ceiling. Only exchange after
bilateral authenticated ready and explicit local per-peer enablement.

## Version 1 connection UI and transport quickstart

The implementation is already available; this is not a proposed disconnected
CRDT. `v12_automatic_sync` installs capture triggers on the existing domain tables,
baselines existing metadata, and projects received changes back into those same
tables and FTS. Recording sealing and provenance-aware analysis publication also
capture resource descriptors in their originating transactions.

```swift
let repository = AutomaticSyncRepository(appDatabase)
// Adapter: lowercase SHA256 hex of the authenticated, pinned peer.publicKey.
let peerID = AutomaticSyncChannel.peerID(peer)
try await repository.configure(peerID: peerID, enabled: true) // consent defaults denied
try await repository.setVoiceprintConsent(peerID: peerID, state: .allowed)
let status = try await repository.status(peerID: peerID)
// status.enabled, status.voiceprints, status.pendingCount, status.conflictCount
try await repository.setVoiceprintConsent(peerID: peerID, state: .paused)
try await repository.setVoiceprintConsent(peerID: peerID, state: .revoked)
try await repository.configure(peerID: peerID, enabled: false)
```

These are separate user actions, not a sequence to execute automatically.
Exact consent cases: `.denied`, `.allowed`, `.paused`, `.revoked`. Settings belong
to the local trusted-key identity, not a discovery name or a payload's device ID.
The adapter checks the current trust store at each boundary; Core does not own
pairing keys. Re-enabling metadata preserves consent instead of granting it.

Transport requires Bonjour TXT `automatic-sync=1` as an **untrusted** compatibility
hint before initiating new messages. Absent that hint, do not probe a legacy peer
with any unknown payload, including a speculative capability hello. The hint
grants neither trust nor permission; negotiate authenticated `hello`/`accepted`
only after existing pairing has completed. Do not add optional fields to frozen
pairing/copy messages or downgrade on failure. Each endpoint pumps its own
`pending(peerID:limit:includeBiometrics:)` outbox and shares one serialized writer
with acknowledgements and heartbeats. Send an operation's fragments contiguously;
`receive(_:from:includeBiometrics:)` takes the authenticated remote willingness;
it cannot override local consent. It returns nil for partial data and the committed operation ID
on completion. Only then send `ack`; the original sender calls
`acknowledge(peerID:operationIDs:)` after checking its in-flight request/operation.
No partial metadata acknowledgement or poll/idle extension is necessary.
Reconnect replays unacknowledged operations from byte zero.

Use `AutomaticSyncWire.encode(_:) -> Data` and `decode(_:) -> Message`;
the App adapter wraps canonical UTF-8 JSON in its encrypted application envelope.
Core has no dependency on App's `MacPairingMessage`. The resource-byte companion
has a separate decoder, capability and offset-based request/ack cycle below.
Neither discovery hints nor remote consent can grant local biometric permission.

The transport must bind each call to the authenticated pinned peer, negotiate
this capability, serialize writes with existing heartbeat traffic, bound
decoding and correlate acknowledgements to sent operation IDs. Discovery is not
authorization. Reconnect replays unacknowledged operations; acknowledgements
follow SQLite commit, not receipt in memory. No wall clock decides winners.

Field registers compare `(Lamport counter, origin device ID, operation ID)`
lexicographically. Each local transaction increments a persistent clock.
Stamp actor and operation IDs must be 1–128 printable ASCII bytes, so Swift
ordering agrees with SQLite BINARY ordering. Legacy entity IDs retain their
separate validation. Duplicate operations compare canonical encoded bytes;
projection compares UTF-8 bytes, preserving NFC/NFD distinctions in winning text.
Remote commits advance it. A delete permanently dominates every field operation
for that entity ID, regardless of arrival order. Association rows have their own
stable ID; removal is permanent for that ID. Re-adding requires a new ID.
All operations are retained as conflict audit, including losing values.

The database generates and persists its replica UUID once. Operation origin is
that replica's identity, not a vendor ID, hostname, discovery label or fallback
string. Entity IDs identify domain records independently of the producer. Historic
IDs remain usable; migration baselines are authored by the migrating replica,
not asserted to be the historic creation event. A claimed stamp device ID is
ordering/producer metadata, not proof of authorship: authenticated `sourcePeer`
and receipt records identify the actual delivering pinned key. Existing domain
`originDeviceId` values are not rewritten as proof of authenticated provenance.

There is no vector clock, dependency frontier or causal-concurrency detector in
v1. Receiving a stamp advances the persistent Lamport clock before later local
writes, but a higher counter alone does not prove causation. Audit/conflict UI
must say superseded values, not proven concurrent edits.

Resource descriptors identify sealed immutable bytes with SHA-256, length,
kind, model fingerprint, preprocessing identity and vector dimensions.
No sender filesystem path or model file is accepted. Audio descriptors require
sealed content; artifacts must identify their input transcript revision.
Resource bytes require independent streaming hash verification before use.
Publication of transcript-derived output checks the input revision against the
current local transcript revision; stale output is retained but not published.

The API's historic `voiceprints` naming covers **all structured biometric
identity metadata**: every speaker field/delete, every meeting-speaker membership
field/delete, utterance speaker assignments, and voiceprint descriptors/bytes.
The receiver derives the required classification from entity/field/resource kind
and rejects false biometric flags. Denied consent must still permit ordinary
unassigned transcript/audio metadata, without leaking hidden speaker IDs.
Free-form recording/transcript content is not automatically de-identified.

Consent defaults to denied for each peer. Both local permission and authenticated
remote willingness must permit biometric exchange. Recheck local state at
operation/chunk boundaries, not just connection startup. Pause stops future
biometric exchange but retains existing local data. Revocation also removes
attributable resource-source contributions and unreferenced imported vector
material; it does **not** erase existing scalar speaker/link projections, their
audit values, or independently retained artifacts. No remote deletion guarantee
is possible. Product UI must describe stopping exchange and limited attributable
resource cleanup, never “erase all biometric data.”

Unpair must persist `.revoked` and disable sync before removing trust/closing the
session. Re-pairing the same public key must preserve that revoked state until a
fresh explicit allow action; metadata reconfiguration cannot grant it. A failure
to persist revocation must not silently complete unpair. Legacy pairing/copy
receipts, existing speakers and embeddings never imply consent. Permissions never
travel as replicated edits. Operational state, local paths, trust keys and model
files do not synchronize.

## Exact metadata codec

JSON is UTF-8, sorted keys, unescaped slashes, absent nil optionals. Decoding
requires byte-identical canonical re-encoding (unknown/duplicate keys and
alternate encodings fail). Message maximum: 2800 bytes, followed by mandatory
actual encrypted-frame limit checking. Do not infer encrypted size from plaintext.

`AutomaticSyncWire.Message`:

* Common: `version: 1`, `kind`, `requestID` (nonempty, at most 128 UTF-8 bytes).
* `hello` / `accepted`: `capability: "automaticSync.v1"` and Boolean
  `voiceprintsAllowed`, the current local willingness to exchange biometrics.
  Both endpoints must allow this; it never changes the receiver's local consent.
* `fragment`: exactly `fragment: {operationID, offset, total, bytes}`.
* `ack`: exactly `operationID`.

`bytes` is canonical padded base64, decoded length 1...768. The metadata generator
emits at most **512** bytes per fragment, leaving additional envelope headroom;
the mandatory actual encrypted-frame check remains authoritative. Fragment offset
and total are byte counts. Total is 1...4194304; offset is nonnegative and
`bytes.count <= total - offset`. Send one operation contiguously at a time.
Reconnection may replay from byte zero: identical stored prefixes are accepted.
Out-of-order gaps and changed prefixes fail without advancing the durable prefix.
Eight incomplete operations per peer is the storage ceiling. An application
acknowledgement is sent only when `receive` returns the complete operation ID.
Retry a lost acknowledgement with the identical operation, not a new ID.
Changing consent to paused, denied or revoked discards that peer's incomplete
metadata buffers atomically with the setting; subsequent retry starts at byte zero.
This does not erase already committed scalar values or claim those buffers
were known to contain only biometric operations.

`Operation`: `stamp: {counter, deviceID, operationID}`, `entity`, `entityID`,
`field`, optional `value`, `isDelete`, `biometric`. Counter is positive signed
Int64 below `Int64.max - 1`. Entity is `meeting`, `speaker`, `utterance`,
`association`, or `resource`. IDs are stable nonempty strings, at most 128 UTF-8
bytes; historic local IDs remain supported. Values are nullable scalar strings
using SQLite's stable text representation, not executable SQL. Null/absent value
with `isDelete: false` explicitly clears a nullable field. Delete requires empty
field and absent value. Resource IDs are the lowercase SHA-256 hex of canonical
descriptor JSON, rather than caller-chosen names.

Allowed fields:

| Entity | Fields |
|---|---|
| meeting | title, emoji, startedAt, durationMs, localeIdentifier, createdAt |
| speaker | displayName, anonymousName, colorIndex, createdAt |
| utterance | meetingId, startMs, endMs, text, speakerId, localeIdentifier, confidence, engine, revision, createdAt |
| association | meetingId, speakerId |
| resource | descriptor |

Integer and probability fields are validated; engine is `appleSpeech` or
`nemotron`. Invalid merged timing intervals are retained in audit but hidden
deterministically, not repaired by changing source timestamps. Unresolved child
references wait in registers for their parent. Parent deletion also tombstones
children subsequently learned from an old operation. A membership is an immutable
ID, not a mutable display index; intentional remove/re-add creates a new ID.
Formally, let `A` map immutable membership IDs to `(meeting, speaker)` pairs and
`D` be the grow-only set of removed IDs. A pair is visible iff an ID in
`dom(A) \\ D` maps to it and both parents exist and are not deleted. Merge retains
the union of removals and the per-field LWW registers; a removal dominates every
write to its same membership ID. Local pair removal tombstones **all observed**
IDs for that pair. An unseen concurrent add with a new ID survives. Thus the
implementation is tagged remove-wins, **not pair-level remove-wins**. Intentional
re-add requires a new ID. Display indices are local, not identity or causality.

**Existing immutable-copy bridge:** v2 lowercases UUIDs while legacy Core rows
may have uppercase UUID IDs. Core register/tombstone lookup canonicalizes valid
UUIDs and resolves an existing equivalent physical domain ID before projection.
Non-UUID IDs remain case-sensitive. New projections preserve a representative
operation's ID spelling; callers must not assume display spelling is identity.
Do not rewrite legacy paths, immutable manifests or copy receipts. This does not
deduplicate arbitrary pre-existing case-only duplicate rows.
`AutomaticSyncIdentityBridgeTests` verifies pre-existing opposite-case UUID
meetings, speakers and utterances on both replicas, bidirectional edits after
database reopen, unchanged resource descriptors/content hashes, and verified
resource adoption against the retained local meeting ID. It also checks that
non-UUID case variants and equal speaker display names stay distinct. These are
Core persisted-copy-shape tests, not execution of the frozen v2 copy importer;
the resource fixture tests byte integrity, not audio codec validity.

## Shared Core integration API

`AutomaticSyncRepository(AppDatabase)`:

* `configure(peerID:enabled:voiceprints:)` creates local per-peer settings.
  Reconfiguring enablement preserves existing consent; use
  `setVoiceprintConsent(peerID:state:)` for explicit consent changes.
* `deviceID()`, `status(peerID:)`, `pending(peerID:limit:includeBiometrics:)`.
* `acknowledge(peerID:operationIDs:)` only for IDs sent and acknowledged in the
  authenticated session; the adapter owns request/session correlation.
* `apply([Operation], from: peerID)` returns committed IDs.
* `receive(Fragment, from: peerID, includeBiometrics:)` returns nil until complete,
  then committed ID. Transport passes the negotiated remote permission explicitly;
  the compatibility default does not bypass the independently checked local gate.
* `audit(entity:id:)`, `values(entity:id:)`, `isDeleted(entity:id:)`.
  Audit retains superseded writes as well as concurrent losers; status
  `conflictCount` is a superseded-register count, not proof of concurrency.
  `receivedFrom(operationID:)` and `resourceSources(id:)` expose authenticated
  delivery provenance separately from a producer ID claimed in a payload.
* `transcriptRevision(meetingID:)` hashes UUID-normalized utterance IDs, exact
  UTF-8 text (including NUL), times, locale, engine, row revision and confidence.
  Private speaker IDs/names are excluded so scalar-only peers compute the same
  input fence; names are never overwritten by transcript publication.
* `registerResource`, `resource(id:)`, `resourcesNeedingDownload(from:limit:includeBiometrics:)`,
  `installResource(id:from:directory:)`, `adoptAudioResource(id:)`,
  `publishResource(id:)`, `publishedResource(meetingID:kind:)`.
  `pendingApplications(peerID:includeBiometrics:)` separately enumerates verified
  incoming resources without durable application provenance. Scan it at startup
  and after metadata changes, attempting each independently. Failed/stale
  candidates remain retryable (missing source dependencies can look stale);
  completed provenance prevents repeated application after later edits.
  `reconcileVerifiedResources(from:includeBiometrics:)` attempts all such
  candidates and returns per-resource `.applied`, `.stale`, `.unavailable` or
  `.failed` outcomes. It does not discard failed candidates or turn byte receipt
  into application success; successful domain commits provide durable markers.
  `verifiedAudioImports()` returns durable adopted incoming audio with meeting ID,
  verified audio SHA-256, byte count, local file URL, authenticated `peerID` and
  descriptor `operationID`. Replay requires that receipt's peer to remain enabled
  and retain its resource-source contribution; enabling an unrelated peer cannot
  authorize replay. Files are re-hashed before queue replay. Scan after adoption and at startup;
  a separate processing queue deduplicates by meeting/configuration/audio SHA.
  Descriptor arrival alone must not enqueue processing.
* `registerVoiceprint(embeddingID:preprocessing:)` requires actual preprocessing
  identity; legacy unknown provenance is not guessed.
  `adoptVoiceprintResource(id:)` requires verified Float32 bytes, a resolved
  speaker and consent, preserving model/preprocessing/dimension namespaces.
  `resourceBytes(id:for:)` rechecks local per-peer consent at send time.
* `collectRevokedFiles()` retries durable file cleanup after restart.
  `cleanupDeletedMeetingAudio(audioDirectory:)` separately drains the v13
  filename journal populated on every meeting deletion, including remote apply.
  Call at startup and on database changes with the application's owned audio
  root. Live meeting/resource/vector references and active transfers retain files;
  traversal, directories and symlinks cannot authorize deleting outside that root.
  Run `collectRevokedFiles()` after that cleanup. v14 meeting-deletion/tombstone
  triggers atomically remove owned non-biometric audio/transcript/analysis payload
  bytes and file/receive records, journaling their files for restart-safe collection.
  The migration also cleans resources of previously tombstoned meetings. Audio
  adoption journals its old CAS path; shared references postpone, not discard,
  its garbage intention. Global voiceprint artifacts are not meeting-owned and
  survive meeting deletion. Operation/audit retention does not retain resource bytes.
* Processing workers MUST call `captureProcessingInput(meetingID:)` **before**
  reading their snapshot and persist its Codable/Sendable `ProcessingInput`
  in the job manifest. The token carries `meetingID`, `audioSHA256`, a local
  `revision` covering all utterance fields, linked speaker records and
  meeting-speaker links, and the consent-independent `transcriptRevision`.
  Use `publishTranscript(input:utterances:publicationID:modelFingerprint:preprocessing:)`
  to compare the entire local token inside the replacement transaction.
  Assignment, link, name, text, timing, audio changes, purge and deletion reject
  stale work without writing any output/outbox. The local identity-sensitive
  fence is not transmitted to peers; resource adoption retains the shared
  content fence and preserves recipient identities through mappings.
  `transcriptPublication(publicationID:)` returns a durable historical receipt
  (`publicationID`, `resourceID`, `outputRevision`) for recovery after commit
  but before the job manifest update, even after subsequent user edits.
  A retry with the original token and identical publication arguments returns
  the original output without reapplying it; changed output/model arguments
  under the same publication ID reject as equivocation.
* `publishTranscript(meetingID:expectedAudioSHA256:expectedRevision:utterances:publicationID:modelFingerprint:preprocessing:)`
  publishes a whole resegmentation; `transcriptMappings(publicationID:)` reads
  its durable source-to-target mapping. The returned String is the output
  transcript revision used by the Mac queue; `publishedResource(meetingID:kind:)`
  returns the immutable resource ID. Output speaker assignment operations are
  separately consent-gated; transcript bytes contain no structured speaker IDs.
  This compatibility API also accepts `expectedUtterances: [Utterance]? = nil`.
  Existing Mac jobs pass their persisted, database-read `previous.utterances`
  snapshot to fence all utterance fields (including speaker assignments) in the
  same transaction without changing the shared hash. Exact committed retries
  precede that fence. Use the richer processing token to additionally fence
  independent speaker/link changes; title-only edits invalidate neither fence.

Migration `v12_automatic_sync` baselines pre-existing metadata without modifying
user rows. SQLite triggers capture normal repository and raw SQL changes in the
same transaction as local mutations. They capture field changes, not unchanged
updates, and generate one stable operation per change. `AppDatabase` uses
`synchronous=FULL`; remote application uses a transaction-local suppression flag.
Applied remote operations retain their immutable IDs/stamps and may be relayed
to another explicitly enabled, authenticated peer, subject to that peer's
biometric consent and independent acknowledgements. They are never echoed to
their recorded source peer or recaptured as new local operations. Internal
`publication:` replacement operations remain suppressed for every peer: their
whole-revision artifact is the authoritative replication unit.

Projection updates only changed columns of affected entities. Missing-parent
arrival/deletion revisits dependent rows; ordinary parent scalar edits do not
rewrite or scan the entire transcript. Duplicate/losing operations do not
reproject or rewrite FTS. UUID aliases are indexed but non-UUID IDs remain exact.
The text codec preserves existing v11 TEXT containing NUL without rewriting
legacy rows; it also supports older GRDB bindings via explicit UTF-8 byte storage.
`AutomaticSyncProjectionScaleTests` imports 1,000 real repository-appended rows
through 10,006 individually completed metadata operations, rather than a bulk
apply. SQL counters assert bounded utterance/FTS rewrites. A following title
rename plus four duplicate replays changes only its one title search document,
not the transcript. Synthetic host timings are diagnostics, not device latency
guarantees.

Sealing a valid hashed recording captures an audio resource descriptor atomically.
`AnalysisResultRepository.record(_:inputRevision:modelFingerprint:preprocessing:)`
checks the input revision and atomically records immutable bytes, descriptor and
analysis provenance. Supply all three provenance arguments together. Legacy calls
remain local-only, rather than inventing a model/preprocessing fingerprint.
Imported analysis publication populates `analysisResult`; `latest` excludes
provenance-bound output once the transcript input changes. Stale results remain
in history. Imported voiceprints may be adopted only through the exact namespace
API; they must never be mixed into a model/preprocessing/dimension-incompatible
matching bank. Unknown legacy preprocessing is not assigned a guessed default.
Production live enrollment (`LiveSpeakerRepository.publish`) and offline enrollment
(`SpeakerAnalysisRepository.apply`, supplied by `SpeakerAnalysisEngine`) capture
known CAMP+ preprocessing artifacts in their existing identity transaction.
`SpeakerRepository.addEmbedding` and speaker merge likewise capture valid vectors;
no later manual `registerVoiceprint` call is required. Enabling a peer or granting
consent also captures valid previously unregistered rows. Legacy missing model or
preprocessing provenance is exported unchanged as opaque, quarantined resources.
Adoption preserves nullable provenance; real matching still requires the exact
model/preprocessing/dimensions. No vector is averaged or assigned guessed provenance.
Voiceprint descriptors carry the source `sampleCount`; absent counts adopt as zero
(unknown), never a fabricated one. Other resource kinds cannot carry sample counts.
The original generated anonymous label is the persisted `speaker.anonymousName`;
renaming `displayName` does not regenerate it.

`AutomaticSyncProductionArtifactTests` exercises both production enrollment
transactions with synthetic post-inference vectors, metadata fragments, verified
resource chunks, global-bank adoption and the actual generation-invalidated
matcher. It rejects incompatible model/preprocessing/dimension spaces and proves
artifact failure rolls back identity enrollment and outbox together. The AAC
resource test resolves the adopted filename through `AudioFileStore`, checks the
sealed meeting hash/byte count/state, decodes non-silent PCM and preserves source
bytes across receive restart. These are pipeline integration fixtures, not evidence
of recognition quality or physical-device playback/latency.

## Input fences, dependencies and retention

Transcript publication commits its exact input transcript hash, sealed audio
SHA-256 check, replacement rows, source-to-target mappings and immutable output
together. Each mapping records source utterance ID, source revision, source
start/end milliseconds and target ID. Current generation maps temporal overlaps;
it does not rebase user corrections or character edits. A target inherits a
local speaker assignment only when its mapped sources agree on one identity.
An explicitly received, consent-gated target assignment can also resolve it.
Target rows otherwise use fresh IDs and remain speaker-unassigned;
old tombstoned IDs cannot be reused. A stale input/audio hash fails publication
without overwriting current edits. The immutable transcript resource is the
replication unit; replacement scalar rows must not bypass the recipient's input
fence. Retries use the same publication ID and exact content.

Scalar operations have no per-edit input revision/precondition. Consequently an
edit to a replaced, tombstoned segment remains in audit and cannot be implicitly
rebased onto a new segment. A future mapping-aware correction workflow needs
explicit validation; v1 does not promise automatic character-level reconciliation.

Acknowledging a descriptor means its metadata transaction committed, **not**
that its file, parent, output or speaker namespace is available. Missing parents
remain pending register dependencies. A transcript can appear unassigned while
its speaker dependency is unavailable; do not invent a speaker. Bytes remain
pending until complete verified installation. Analysis/transcript adoption further
requires the exact current input; voiceprints require their speaker, consent and valid
vector storage. A missing namespace permits quarantined storage, not matching.
`resourceUnavailable`/`staleRevision` must remain visible pending/stale outcomes,
not fictitious successful materialization. Resource adoption can be retried after
dependencies arrive; metadata acknowledgement must not enqueue audio processing.
Only `verifiedAudioImports()` authorizes that post-adoption work.

Operations, superseded audit values, tombstones and peer acknowledgements have
indefinite retention. There is no all-device horizon or operation/tombstone GC
in v1. Any future collector needs an explicit horizon covering every relevant
replica or explicit retirement with a full reseed policy. Unpair, elapsed wall
time, a single receiver acknowledgement or source-file receipt is not that
horizon. Local byte quotas/revocation cleanup do not authorize metadata GC.

Resource cleanup is reference-aware: remove the revoked peer's biometric
contribution, then retain any artifact needed by independent local provenance or
another peer contribution. Shared physical paths must not be unlinked while
another descriptor/transfer references them. Garbage intentions commit before
filesystem deletion and remain restart-retryable. Do not broadcast a global
resource tombstone to implement local consent revocation. Scalar identity audit
and projections are retained under the limited revocation policy above.

## Optional immutable-byte companion

Only advertise/accept `automaticSyncResources.v1` after its receiver is integrated.
It uses a separate encrypted application type of that exact name. No fallback
to plaintext, v1 or immutable-copy operation is allowed.

`AutomaticSyncResourceWire.Message` common keys are `version: 1`, `kind`,
`requestID`. `hello`/`accepted` have no additional keys; `request`/`ack` contain
`resourceID` and nonnegative `offset`; `unavailable` contains `resourceID`;
`chunk` contains `chunk: {resourceID, offset, total, bytes}`. Resource IDs are
64-character lowercase SHA-256 hex. Bytes are 1...768, total 1...8 GiB, with the
same subtract-before-add bounds and canonical message/frame constraints.
Request a known descriptor at the receiver's durable offset. The sender answers
one chunk; receiver acknowledges the committed next offset. Re-request that
offset until it equals the descriptor byte count. A final ack follows full-file
SHA-256 verification and SQLite installation, not merely the last network write.

`AutomaticSyncResourceTransfer(db, directory: localRoot, quotaBytes:)` exposes
`chunk(resourceID:offset:for:audioDirectory:)`, `progress(resourceID:from:)`,
`receive(_:from:)` and `discardPartial(resourceID:from:)`. Each chunk rechecks
peer enablement and biometric consent. Incoming paths are generated locally.
Files are synchronized before durable prefix commits; crash-written tails are
truncated to the committed prefix. Completion verifies SHA-256 with 64-KiB reads,
syncs a separate immutable final file and its directory, then records availability.
Lost final acknowledgements are idempotent. Damaged prefixes can be explicitly
discarded and downloaded again without touching the source recording.

Default storage budget is 512 MiB and reserves staging plus final-copy space,
including existing installed resources. This is local policy, not a negotiated
promise to accept the 8-GiB wire ceiling. An adapter maps unavailable/over-quota
resources to `unavailable`; it does not retry endlessly or claim success.
After completion install audio into the application's actual audio directory and
call `adoptAudioResource`, or call `publishResource` for current-input analysis.
The original sender file is never modified; receipt grants no purge permission.

## Acceptance boundary

### Committed-change observation and legacy baseline

`AutomaticSyncRepository.changes()` returns a cancellable async sequence of
coalesced post-commit invalidations, including an initial startup value. Own its
iteration in the model/workspace lifetime, not an intermittently mounted view.
On each signal re-query domain projections and `verifiedAudioImports()`, and
reconcile verified resources waiting on dependencies. This is not a per-operation
receipt API: a descriptor commit does not imply playable/adopted bytes. Rollback
produces no signal; resource/adoption-table updates do, even without row-count
changes. The observation registers table access without loading resource blobs.

Migration snapshots use one baseline Lamport epoch (`1`), independently of row
count or iteration order. Baseline operations have deterministic identities
within the actual persistent replica; pre-existing memberships have deterministic
pair identities. Later local mutations start above that epoch, so a large legacy
database cannot overwrite a fresh edit merely because its migration read more
rows. Snapshotting does not mutate existing physical origin columns, create peer
permission records, or infer embedding preprocessing or consent.

Core tests use synthetic in-memory/on-disk databases and encoded fixtures: seeded
multi-replica/reordered/duplicate merges, restart tombstones and prefixes, atomic
rollback/no echo, source provenance, consent pause/revoke, independent peer
contributions, quotas, corrupt final bytes, audio immutability and stale analysis.
The sealed-audio restart test encodes an actual one-second AAC/M4A tone, transfers
and adopts it, then decodes non-silent PCM and verifies sender-byte preservation.
The voiceprint fixture encodes valid Float32 values through the companion codec,
verified resource store and actual matcher; incompatible namespaces/dimensions
and revoked matcher entries are covered separately. Fixture vectors are not
model-inference or speaker-recognition quality evidence. Imported embedding
origins use the descriptor operation's persistent replica, not a synthetic label.
They do not certify LAN discovery, encrypted app dispatch, physical-device
thermal behavior, model quality or two-product UI acceptance. Resource transport
must be explicitly integrated and negotiated by both products; metadata-only
integration is not complete audio/artifact synchronization.

### Current review gates, not completed acceptance claims

The latest concurrent implementation refinements need revalidation; older green
Core results do not validate changed identity/consent/publication behavior.
In particular, verify:

* Case-equivalent UUID identities preserve existing physical rows and stale
  tombstones; projected origin values use real operation replicas. The association
  projection still uses a synthetic `originDeviceId='sync'` and must be corrected
  or explicitly excluded as an authorship source.
* Revoke resource-source cleanup is confined to biometric contributions; the
  encoded-audio test verifies that delivery references and durable import
  reconciliation survive voiceprint revocation.
* Explicit consent gates identities/links in both directions, including buffers,
  reconnect and unpair/re-pair. Existing identity rows are not promised erased.
* Resegmentation retries reject mismatched content using the same publication ID,
  and source mappings/input fences survive restart and out-of-order delivery.
* Dependencies arriving after a descriptor eventually trigger adoption in both
  products rather than leaving an acknowledged resource permanently pending.
