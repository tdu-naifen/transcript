# ADR: typed, durable local replication (2026-09-07)

Status: accepted for the shared foundation; product transport acceptance is separate.

Automerge provides causal documents and text editing; Yjs provides mature text
collaboration but requires a JavaScript runtime/bridge here. Both still require
SQLite materialization, biometric consent, authenticated transport and immutable
file handling. This product edits scalar metadata and publishes whole transcript
revisions, not collaborative character sequences. We choose a small typed
operation CRDT with persistent Lamport field registers, permanent remove-wins
tombstones, an append-only conflict history and immutable resource descriptors.
No dependency is added. A future text editor should reconsider Automerge rather
than extend this register implementation into an invented text CRDT.

TranscriptCore owns the canonical metadata/resource DTOs and codecs. Shared
compatibility files only import and typealias those public definitions; there is
no second production DTO implementation or app-specific codec compilation.

SQLite transactions encompass local mutations, clock allocation and operation
capture. Remote application is idempotent and suppresses mutation capture.
Operation retention is indefinite: disconnected devices must not resurrect
deleted IDs. Restoring an item requires a new ID. Biometric authorization is
local, explicit and per paired device; it is never replicated as permission.
The frozen immutable-copy v2 and pairing codecs remain unchanged.

## Decision boundaries

* Discovery TXT `automatic-sync=1` is an untrusted compatibility hint, not consent
  or authentication. Without it, do not probe a legacy decoder with new payloads.
  Negotiate the independent capability only inside the authenticated channel.
* A replica UUID is generated once in the local database. Entity IDs remain
  domain identities; neither vendor/device-name fallbacks nor discovery names
  establish identity or historical authorship. Authenticated delivery provenance
  is distinct from an operation's claimed origin.
* Scalar registers have Lamport ordering, not vector-clock causal context.
  Audit records cannot distinguish concurrent writes from sequential overwrites.
  Transcript publication instead fences exact input/audio revisions and records
  source-to-target segmentation mappings. These are not text-CRDT merge rules.
* Remove-wins is permanent **per entity/membership ID**. An association pair is
  visible when any nonremoved membership tag exists. Removing observed tags does
  not remove an unseen concurrently created tag: this is not pair-level
  remove-wins. Stronger pair-level semantics require a protocol revision.
* Descriptor acceptance records a dependency, not usable audio or a completed
  artifact. Verified bytes, parents, consent and current-input checks gate adoption.
* Consent gates speaker identities, links and voiceprints, not only vector bytes.
  Unpair revokes this local permission, including when the same key later re-pairs.
  Legacy records do not imply consent or known model/preprocessing provenance.
* Revocation stops future biometric exchange and removes attributable resource
  contributions only when independent local/other-peer references do not need
  them. It is not global erasure: existing scalar identity projections and audit
  history remain. Product wording must not promise their deletion.
* No operation/tombstone garbage collection is implemented. Any future collector
  needs an explicit all-device acknowledgement/retirement horizon; a single
  transfer receipt, timeout or unpair is insufficient. Retention is indefinite.

See `SYNC_CONTRACT.md` for exact semantics and remaining acceptance gaps; the
existence of these decisions is not evidence of two-product acceptance.
