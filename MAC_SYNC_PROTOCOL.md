# Immutable meeting copy v2 — iOS implementation / Mac receiver handoff

This replaces the previous **DRAFT NOT ENABLED** DTO proposal. The normative
codec is `Shared/Sync/MeetingCopyWire.swift`; the old `TranscriptTransferDraftV2`
files are historical proposals, **not this wire**. iOS now has a real authenticated
sender, SQLite outbox, manual UI, and a loopback TCP/filesystem/SQLite test receiver.
**This is not a claim that the production Mac app receives copies.** Its owner
must implement and independently qualify the receiver below. No Mac production
files or frozen `Shared/Pairing` cryptography are changed by the iOS work.

### Fixed-source handoff boundary

The contract-only delivery consists of this document and
`Shared/Sync/MeetingCopyWire.swift`. Add that Swift file explicitly to the Mac
target alongside the existing unchanged pairing sources; do not include the
historical draft DTOs. The sender, outbox, migrations, UI and receiver have
separate implementation and acceptance gates. A contract commit does not enable
transfer in either product or certify their uncommitted implementations.

## Scope and explicit non-goals

One user-authorized, immutable, new-meeting copy: stable original meeting UUID,
title/times/locale, original sealed audio bytes and SHA-256, and the published
local timed transcript with a frozen export revision, parent and source.
The iOS source audio is never rewritten. No embeddings, global speaker bank,
speaker identity records, filesystem paths, account/device identifiers, or model
files travel in this wire. Utterance IDs are meeting payload IDs, not speaker IDs.

No automatic overwrite, last-writer-wins, merge, result return, remote processing,
deletion propagation, cancellation rollback or purge permission is implemented.
Local edits, Mac-produced results, deletions and multi-device conflict decisions
remain joint design work. Existing meeting ID **or tombstone** is an explicit
`conflict`, even if bytes seem identical. Only retry of the **same committed
operation with the same manifest** may return its already persisted receipt.

## Compatibility, authorization and connection ownership

1. Continue advertising `_vtscribe._tcp`. A receiver supporting this exact v2
   protocol adds TXT `meeting-copy=2`. This value is **untrusted** and authorizes
   nothing: it only opts the selected endpoint into a metadata-free protocol probe.
   An endpoint configured explicitly by a test may use the same opt-in boolean.
   v1/absent hints are never probed or sent application payloads.
2. The existing commit/reveal, identity proof, explicit first-pair approvals,
   pinned reconnect and bilateral `ready` are unchanged. No extra v2 bytes appear
   in the handshake. A pin mismatch fails; never retry as unpaired/plaintext.
3. After authenticated ready, **only explicit user Send/Retry** sends the
   `capabilities` message below. Opening a view, receiving a TXT hint, connecting,
   reconnecting or restoring the queue sends no meeting data and no probe.
4. The peer must answer `accepted` with the exact capability and request ID in
   that authenticated session before any manifest/audio/transcript is sent.
   The client publishes `supportsMeetingTransfer = true` only then.
   It resets immediately on disconnect/reconnect. A button press or `.connected`
   never means transfer-ready.
5. A v1 server closes unknown messages. If a spoofed/stale hint causes a probe to
   reach v1, EOF/timeout is an unsupported/interrupted transfer error, **not lost
   trust**. Explain update/reconnect; retain the pinned identity. No downgrade,
   unpair, unsolicited pairing, plaintext, or new-payload retry fallback.

After ready, the encrypted `MacPairingMessage` has type `"meetingCopy.v2"` and
`value` is the UTF-8 JSON **string** of a v2 Message (not a JSON object or base64).
Use existing `MacPairingCipher.seal/open`. Each direction keeps its existing
strict monotonic counter across auth/ready, ping/pong and application messages.
Counter starts/rekey behavior stays v1. There is one reader and one ordered writer
per session. The iOS dispatcher routes pong separately from the sole pending RPC.
Only one transfer and one application RPC can be active; callbacks cannot consume
the socket independently. Heartbeats use the same counter allocator/send chain.

The sender correlates every response to a fresh UUID `requestID`, exact operation,
current session token and expected response type. Unsolicited, duplicate, replayed,
unknown, mismatched or malformed messages close the session. The application RPC
deadline is 30 seconds independent of pong traffic. Disconnection resolves pending
RPCs, cancels the reader and leaves noncommitted queue entries unsent.

## Exact codec and bounds

All nested JSON uses the reference `MeetingCopyWire.encode`: UTF-8, sorted ASCII
keys, no whitespace, no escaped `/`, canonical JSON string escaping, no BOM.
Optional keys are **absent**, not null. UUIDs are lowercase canonical nonzero
36-byte strings. SHA-256 values are exactly 32 bytes encoded as canonical padded
base64 (44 ASCII bytes). `Data` fields use canonical padded base64. Integers are
decimal JSON integers, never floating point/exponent/string forms.

The decoder rejects unknown/duplicate keys, alternate encodings and null optionals
by requiring decode→canonical-reencode byte equality, then validates the exact
allowed key set for the message type. Preserve and hash the **exact manifest
bytes**, not a parsed/re-encoded representation on another JSON implementation.
Mac may use the same source codec; using a different codec requires byte-vector
interop verification.

The outer v1 framing is unchanged: 4-byte big-endian length followed by at most
**4096 actual serialized encrypted outer JSON bytes**. Check the final frame
after encryption and before writing any header/bytes. Raw chunks are at most
768 bytes. (1024 bytes of `0xff` exceeded 4096 after v1 JSON slash escaping.)
Message JSON is at most 2800 bytes and manifest JSON at most 1600
bytes; actual encrypted-frame validation is still mandatory. Do not infer fit
from raw chunk size. The transcript file is at most 16 MiB, audio at most 8 GiB.
Read/write/hash audio incrementally; never allocate its declared total size.
Offsets use UInt64 but must pass `offset <= length` then
`chunk.count <= length - offset` before addition. Never trust a sender path.

These are protocol ceilings, not a promise of receiver capacity. This version
negotiates the capability string only, not size limits. A receiver with a lower
local storage/quota limit must reject an oversized offer with `failed/storage`
before returning `status` or accepting asset chunks. The sender retains its
original audio and must not mark that copy confirmed. Do not add private limit
fields or describe a local receiver limit as negotiated; test this rejection
explicitly during receiver integration.

### Struct schemas

Names/case here are exact. No fields other than these are allowed.

- **Asset**: `{"length": UInt64, "sha256": base64SHA256}`.
  Audio length 1...8 GiB, transcript length 1...16 MiB.
- **Operation**: `{"id": UUID, "meetingID": UUID,
  "manifestSHA256": base64SHA256}`.
- **Prefix**: `{"asset": Asset, "offset": UInt64,
  "prefixSHA256": base64SHA256}`. `offset` is the count of durably present
  contiguous bytes beginning at zero. Prefix digest hashes exactly those bytes.
  Empty prefix SHA-256 is `47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=`.
  Full Asset identity and total length bind every resume/ack to its offered asset.
- **Manifest**:
  `meetingID`, `title`, `startedAtMs`, `createdAtMs`, `updatedAtMs`,
  `durationMs`, optional `locale`, `audio` (Asset), `transcript` (Asset),
  `transcriptRevision` (UUID), optional `parentRevision` (UUID),
  `source` = `"publishedLocalTranscript"`.
  Title is nonempty, <=512 UTF-8 bytes. Timestamps are integer UTC Unix
  milliseconds in 0...253402300799999; updated >= created. Duration is
  0...604800000 ms. Locale is nonempty <=64 ASCII bytes, letters/digits/`-._/`
  as accepted by reference `validLocale` (the reference codec is authoritative).
  Parent cannot equal revision.
- **Transcript** file JSON:
  `revision` (same UUID as manifest), optional `parentRevision` (same as manifest),
  optional `locale` (same as manifest), `utterances` (array).
  This revision is a newly assigned **frozen export revision**, not a claim that
  Core has already implemented a global revision DAG. Initial parent is absent.
  Per-row published revision/source are preserved.
- **Utterance**:
  `id` UUID, `startMs` Int64, `endMs` Int64, `text` string, optional `locale`,
  `revision` integer 1...2147483647, `source` `"appleSpeech"` or `"nemotron"`.
  At most 100000 unique IDs; array nondecreasing start time (tie ordered by local
  ID); `0 <= startMs <= endMs <= durationMs`; text <=65536 UTF-8 bytes.
  No global speaker identity/voiceprint fields.

### Message schemas and transitions

Every message has exactly these common keys:
`version: 2`, `type: <below>`, `requestID: UUID`.
Request IDs are fresh for every request/retry; responses echo the request ID.
These are the **only additional keys**, all required unless described otherwise:

| type | additional keys | response |
|---|---|---|
| `capabilities` | `capability: "immutableMeetingCopy.v2"` | `accepted` |
| `accepted` | `capability: "immutableMeetingCopy.v2"` | none |
| `offer` | `operation: Operation`, `manifest: base64(exact manifest JSON)` | `status`, `committed`, `failed` |
| `status` | `operation`, `audio: Prefix`, `transcript: Prefix` | none |
| `chunk` | `operation`, `asset: "audio"\|"transcript"`, `offset: UInt64`, `bytes: base64` (1...768 decoded bytes), `sha256: base64SHA256(chunk)` | `ack`, `failed` |
| `ack` | `operation`, `asset`, `prefix: Prefix` | none |
| `finalize` | `operation` | `committed`, `failed` |
| `committed` | `operation`, `receiptID: UUID` | none |
| `failed` | `operation`, `failure: string` | none |

Failure vocabulary: `incompatible`, `invalid`, `conflict`, `storage`,
`staleSnapshot`, `cancelled`, `busy`. Metadata-free negotiation has no operation:
reject/close instead of inventing an operation-bearing failure.

Golden capabilities plaintext (before wrapping in `MacPairingMessage.value`):

```json
{"capability":"immutableMeetingCopy.v2","requestID":"11111111-1111-1111-1111-111111111111","type":"capabilities","version":2}
```

## Receiver requirements (production Mac owner)

After accepted capabilities:

1. Offer validates raw manifest bounds/canonical bytes/hash and meeting ID.
   Bind staging to authenticated client public key + operation ID + exact bytes.
   Reuse with changed operation/manifest/asset/meeting is invalid. Operation replay
   from another identity must not expose metadata or a receipt.
2. In a durable transaction, check existing meeting **and tombstone**. Different
   operation collision is `failed/conflict`, with no overwrite or deletion.
   Persist staging binding before accepting chunks. Create internal safe files,
   never paths supplied over the network. Apply quotas, reserve disk space and
   bound staged-operation lifetime/resource use (production-specific gate).
3. Return `status` only for the bound operation. Re-hash actual durable contiguous
   file prefixes; do not trust an in-memory offset/timer. Report full Asset
   descriptors plus prefix offsets/digests. On retry, iOS verifies descriptors,
   hashes local prefixes and starts exactly there. It never trusts local cached
   progress as authoritative.
4. For each chunk verify operation binding, asset, offset, <=768 length and chunk
   hash before bounded positional write. No gaps, overlap, overflow or truncation.
   Persist/fsync bytes and durable prefix accounting before `ack`. A repeated
   offset in the current session is not a new write; fail closed in this protocol.
   Reconnect uses `offer/status`, not an ambiguous replayed chunk.
5. `ack` must echo operation, request ID and asset; its prefix must have exactly
   expected next offset, full Asset identity, and newly computed prefix digest.
6. `finalize`: re-read/hash both complete files, validate canonical transcript and
   manifest relationship, then fsync files + containing directory and commit
   meeting metadata, immutable assets, source transcript and **stable receipt ID**
   in a SQLite transaction. Collision check repeats in this transaction. Only
   after successful durable commit may `committed` be emitted.
7. After crash or dropped receipt, repeated identical offer returns that stored
   receipt ID without duplicate import. Never use timer, queue acceptance or
   socket completion as a durable receipt. A receipt is an authenticated **remote
   claim**; iOS cannot inspect Mac fsync. Production receiver tests must prove it.
8. Local iOS cancellation closes the transport; there is no cancel/delete wire.
   The remote may retain staged bytes or already committed data. No rollback
   acknowledgment is fabricated. Staging cleanup must not delete committed data.

The app fixture receiver demonstrates these filesystem/hash/transaction ordering
requirements on isolated test data, but is not production authorization, quota,
recovery, tombstone UI or storage architecture.

## iOS persistence and UI

`v9_local_immutable_meeting_copy_outbox` only adds the local
`meetingCopyOutbox` table and export-invalidating source triggers. It does not
alter any remote schema or introduce delete replication. The queue owns frozen
manifest/transcript/snapshot bytes, original file identity, peer public key,
stable operation ID, state (`queued`, `cancelled`, `stale`, `done`), error and
authenticated receipt. A `(meetingId, peerKey)` unique constraint prevents a
second ambiguous export operation to the same destination.
Enqueue also atomically caps the local outbox at 200 entries and 64 MiB of frozen
payload/snapshot bytes. A full queue fails without evicting receipts; automatic
retention/receipt archival is not implemented.

Enqueue hashes sealed audio off MainActor, checks file identity (regular,
non-symlink, device/inode/size/mtime), then atomically revalidates the source DB
snapshot and saves the owned export bytes. Source edits invalidate pending
exports; they cannot silently substitute newer text/bytes. Every request checks
the durable queue state; full snapshot is checked at start and receipt commit.
Before each attempt and before finalize, audio is streamed and verified against
the original sealed SHA-256; chunk reads check file identity. There is no 8-GiB
Data allocation or capture-session lock. Per-chunk queue checks do not rescan the
whole transcript.

Send and Retry are explicit. Restart/reconnect reload jobs, not automatic data
transfer. EOF, invalid ack, failed resume, local cancellation and stale source
never set `syncedToMacAt`. A valid operation-bound committed receipt and final
source validation atomically set queue `done` and `meeting.syncedToMacAt`.
Outbox mutation transactions explicitly use SQLite `synchronous=FULL` on the
serialized writer, then restore its prior mode, including enqueue/cancel/receipt.
`audioVerifiedOnMacAt` is deliberately **not** set: this protocol grants no local
audio-purge permission. No meeting state/analysis result is changed.

UI says immutable copy, not Mac processing/result sync. The legacy entry point
may still be named “Process by Mac” in older presentation; the confirmation
explicitly describes the narrower copy scope. Queue jobs distinguish confirmed
copy from “not delivered / retry” and “stopped on iPhone / Mac may retain a copy.”

## Verification / remaining integration gates

`AppTests/MeetingCopyTransferTests.swift` uses existing XCTest, real loopback-only
Network.framework TCP, the real client and unchanged cipher, isolated audio files
and a SQLite test receiver. It exercises positive durable commit, interrupted
prefix resume, stable operation restart, lost receipt/idempotent reoffer, old
server EOF, no-probe hint path, audio tampering, stale edits, mismatched/replayed
acks, cancellation/retry, collision/tombstone and codec/4096-byte boundaries.
This is a **native iOS protocol harness**, not production Mac app interoperability.

Production Mac receiver implementation + independent contract/security review,
crash durability/failure injection, actual Mac↔simulator interop, and joint future
edit/result/deletion policies remain gates. No user phone, microphone, real LAN
Mac, firewall change or automatic production data transfer is needed for this
harness. Build/runtime results are reported separately after validation.
