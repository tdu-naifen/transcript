# Transcript local pairing protocol v1

This is the interoperability contract for the native Mac implementation and an
iOS client. This is an application-layer encrypted protocol over TCP, **not TLS**.
It uses CryptoKit X25519, Ed25519, HKDF-SHA256 and ChaCha20-Poly1305. It is a
commit-before-reveal short-authentication-string (SAS) exchange, not a claim of
implementing an externally audited standard. Never silently accept a certificate,
derive a SAS from only public exchanged keys, or bypass the comparison.

## Discovery and framing

Bonjour `_vtscribe._tcp`, domain `local.`. Bonjour names are untrusted labels.
On macOS, Local Network privacy permission and Firewall permission for incoming
connections are separate. Discovery may succeed while a pending Firewall
Allow/Deny prompt prevents the TCP pairing exchange. A discovery or TCP setup
failure is not an authentication failure. The app explains both settings; it
does not grant permissions, dismiss system prompts or disable the firewall.
Every frame: unsigned 32-bit big-endian JSON byte length, then UTF-8 JSON.
Length must be 1...4096; EOF, invalid fields/order, oversized frames, bad crypto,
wrong sequence or deadline expiry terminates the connection without trusting it.
JSON object fields: `type` (string), `payload` (standard padded base64 string,
optional), `mode` (`pair` or `reconnect`, only commit), `counter` (UInt64, only sealed).
No other frame types, extension negotiation, or meeting content are supported.

## Commitment and key exchange (strict order)

Client = iPhone, server = Mac. Domain `D` is UTF-8 `TranscriptPairing/v1/`.
Each connection generates a fresh X25519 ephemeral key and 32 random nonce bytes
using the OS CSPRNG. Each device has a persistent Ed25519 identity in Keychain.
Hello canonical bytes `H`:

* mode byte: 0 for pair, 1 for reconnect
* Ed25519 identity public key: 32 raw bytes
* X25519 ephemeral public key: 32 raw bytes
* random nonce: 32 bytes
* name UTF-8 byte count: UInt16 big-endian
* display name: 1...63 UTF-8 bytes (untrusted, no control characters).

Client chooses mode; server uses the same mode. Role bytes are UTF-8 `client`
and `server`. Commitment `C(role,H) = SHA256(D || "commit/" || role || H)`.

1. Client → server: `{"type":"commit","mode":"pair","payload":base64(C(client,Hc))}`
2. Server → client: same shape, same mode, `C(server,Hs)`.
3. Client → server: `{"type":"reveal","payload":base64(Hc)}`
4. Server validates commitment, mode, canonical hello and any reconnect pin;
   server → client: reveal of `Hs`.
5. Client validates commitment, mode and (on reconnect) expected server pin.

Neither endpoint may reveal before receiving the other's commitment. No retries
within a connection. Reconnect MUST fail closed if the expected stored identity
does not match; NEVER fall back automatically to pairing. New pairing requires
explicit Mac pairing enablement (120 seconds / at most five attempts) and user
comparison on both devices. At most one live connection is accepted.

`T = SHA256(D || "transcript/" || Hc || Hs)`.
`Z = X25519(local ephemeral private, remote ephemeral public)`.
Reject invalid/low-order keys (CryptoKit shared-secret operation).
HKDF-SHA256 uses IKM Z, salt T and:

* info `D || "c2s"` → 32-byte client-to-server key
* info `D || "s2c"` → 32-byte server-to-client key
* info `D || "sas"` → 8 bytes, read UInt64 big-endian, modulo 1,000,000,
  formatted as exactly six decimal digits including leading zeros.

Display this SAS only after verifying the encrypted peer identity proof below.
It authenticates this whole committed exchange *only after users compare and
approve the same digits on both screens*. Before that, encryption is provisional.
An active attacker gets approximately one chance in a million per user-approved
attempt; commitments prevent adaptively grinding the SAS after key reveal.
Users must reject mismatches; repeated requests must not be auto-approved.

## Encrypted channel and identity proof

All subsequent frames are `{"type":"sealed","counter":N,"payload":base64(combined)}`.
Each direction independently starts at counter 0 and requires exactly the next
counter. `combined` is CryptoKit ChaChaPoly `nonce || ciphertext || tag`.
Nonce is four zero bytes followed by UInt64BE counter. Reject any different
nonce. AAD = `D || "sealed/" || direction || T || UInt64BE(counter)`,
where direction is `c2s` or `s2c`. No nonce reuse: derive new keys per connection;
terminate before counter overflow. Inner plaintext is a JSON object with `type`
and optional string `value`.

6. Client → server encrypted `{"type":"auth","value":base64(signature)}`.
   Ed25519 signature over `D || "auth/" || "client" || T`.
7. Server verifies with committed client identity; sends encrypted auth signed
   over `D || "auth/" || "server" || T`. Client verifies committed server identity.
8. For pair, show SAS and device name; each endpoint requires explicit local
   “Codes Match” approval. Client sends encrypted `{"type":"approve","value":SAS}`.
   Either side can send encrypted `{"type":"reject"}` and close.
   Mac waits for BOTH local approval and correct client approval; neither alone
   is sufficient. No identity is persisted before both approvals.
   A client may revoke approval by sending encrypted `reject` or disconnecting
   while Mac confirmation remains pending. Mac continues reading during that
   wait and immediately invalidates the request when it observes rejection,
   EOF or an unexpected message; a subsequent stale UI click cannot save trust.
   For reconnect, skip UI ONLY after pin and signature verification, and client
   sends encrypted `{"type":"resume"}` instead of approve.
9. Mac persists the peer identity on first pairing, then sends encrypted
   `{"type":"ready"}`. Client persists Mac identity only after this message and
   its own local approval, then sends encrypted `{"type":"ready"}`.
10. Mac marks the live connection authenticated only after client ready.

The durable trust boundary is bilateral approval, not successful socket setup.
A drop between trust writes can leave one-sided trust: report failure and
require explicit re-pair/unpair, never downgrade a failed reconnect. Pin storage
is keyed by identity public key, not a mutable Bonjour name or address.

## Established channel, lifecycle and limits

Only encrypted `ping` → `pong` is currently supported after ready. No audio,
transcript, metadata, file names or meeting list transfer exists, even after
pairing. Future transfer requires a separate versioned protocol and must be
gated on the authenticated state. Unknown messages close the connection.
Cross-device meeting deletion, tombstones, synchronization acknowledgments and
voiceprint lifecycle synchronization are also out of scope and are not
implemented. This protocol defines no generic application-data envelope and no
reserved delete message semantics. Pairing or unpairing never deletes meetings
or voiceprints; any future deletion-sync contract must be agreed separately.
Initial handshake deadline: 10 seconds from accept (including partial frames).
After verified auth, pairing approval deadline: 60 seconds, including ready.
Reconnect retains the 10-second deadline. Authenticated sessions have a
120-second idle timeout; clients should ping well before this.
Disconnect clears live state, not stored trust. Stopping discovery closes the
live connection. Unpair removes the Keychain pin first and closes any live
connection; later reconnect with that identity fails.
Errors do not expose secrets or internal crypto failures on the wire.

## Security boundary

Persistent identity and peer pins use non-synchronizing, device-only Keychain
items. A local compromise, users approving unequal codes, or an attacker with
one device's private identity key is outside this protocol's protection.
The short SAS is not a password and is never used directly as an encryption key.
The two-commit exchange is essential: removing either commitment breaks its
active-attacker resistance. This custom composition should receive independent
cryptographic review before production deployment with private data transfer.
