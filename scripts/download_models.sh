#!/bin/bash
#
# Fetch the Nemotron 3.5 ASR Streaming CoreML bundles into ./Models (gitignored).
#
# Idempotent: every file is verified against the sha256 that the Hugging Face
# tree API reports for its LFS object. Files that already verify are skipped, so
# re-running costs one API call and no bytes.
#
#   scripts/download_models.sh                    # multilingual/2240ms (default)
#   scripts/download_models.sh latin/560ms        # some other tier
#   VERIFY_ONLY=1 scripts/download_models.sh      # check an existing copy
#
set -euo pipefail

REPO="FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML"
VARIANT="${1:-multilingual/2240ms}"
REVISION="${MODEL_REVISION:-main}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/Models/nemotron-asr/$VARIANT"
TREE_JSON="$(mktemp -t nemotron-tree)"
trap 'rm -f "$TREE_JSON"' EXIT

log() { printf '%s\n' "$*" >&2; }

# Two concurrent runs deadlock on the downloader's own per-file locks.
LOCK="$ROOT/Models/.download.lock"
mkdir -p "$ROOT/Models"
if ! mkdir "$LOCK" 2>/dev/null; then
    log "error: another download is already running (remove $LOCK if stale)"
    exit 1
fi
trap 'rm -f "$TREE_JSON"; rmdir "$LOCK" 2>/dev/null || true' EXIT

log "repo     $REPO@$REVISION"
log "variant  $VARIANT"
log "dest     $DEST"

api="https://huggingface.co/api/models/$REPO/tree/$REVISION/$VARIANT?recursive=1"
if ! curl -fsSL --retry 3 --retry-delay 2 -m 120 "$api" -o "$TREE_JSON"; then
    log "error: cannot reach the Hugging Face tree API"
    exit 1
fi

# path<TAB>size<TAB>sha256 for every regular file in the variant.
FILES="$(python3 - "$TREE_JSON" "$VARIANT" <<'PY'
import json, sys
tree = json.load(open(sys.argv[1]))
prefix = sys.argv[2].rstrip("/") + "/"
rows = []
for entry in tree:
    if entry.get("type") != "file":
        continue
    path = entry["path"]
    if not path.startswith(prefix):
        continue
    lfs = entry.get("lfs") or {}
    rows.append("\t".join([
        path[len(prefix):],
        str(lfs.get("size") or entry.get("size") or 0),
        lfs.get("oid") or "",
    ]))
if not rows:
    sys.exit("no files found — is the variant path correct?")
print("\n".join(sorted(rows)))
PY
)"

total_bytes=0
while IFS=$'\t' read -r _ size _; do
    total_bytes=$((total_bytes + size))
done <<< "$FILES"
log "$(wc -l <<< "$FILES" | tr -d ' ') files, $((total_bytes / 1000000)) MB"

sha_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

# A file is "good" when it exists and either matches the published sha256 or —
# for the small non-LFS files HF serves without an oid — matches the byte count.
is_good() {
    local file="$1" size="$2" want="$3"
    [[ -f "$file" ]] || return 1
    local have
    have="$(stat -f%z "$file")"
    [[ "$have" == "$size" ]] || return 1
    [[ -n "$want" ]] || return 0
    [[ "$(sha_of "$file")" == "$want" ]]
}

missing=()
while IFS=$'\t' read -r rel size want; do
    is_good "$DEST/$rel" "$size" "$want" || missing+=("$rel")
done <<< "$FILES"

if [[ ${#missing[@]} -eq 0 ]]; then
    log "✅ all files present and verified"
    exit 0
fi

if [[ -n "${VERIFY_ONLY:-}" ]]; then
    log "❌ ${#missing[@]} file(s) missing or corrupt:"
    printf '   %s\n' "${missing[@]}" >&2
    exit 1
fi

log "${#missing[@]} file(s) to fetch"

if command -v hf >/dev/null 2>&1; then
    log "using hf CLI"
    patterns=()
    for rel in "${missing[@]}"; do patterns+=(--include "$VARIANT/$rel"); done
    hf download "$REPO" --revision "$REVISION" \
        --local-dir "$ROOT/Models/nemotron-asr.hf" "${patterns[@]}" >&2
    mkdir -p "$DEST"
    for rel in "${missing[@]}"; do
        mkdir -p "$DEST/$(dirname "$rel")"
        mv -f "$ROOT/Models/nemotron-asr.hf/$VARIANT/$rel" "$DEST/$rel"
    done
    rm -rf "$ROOT/Models/nemotron-asr.hf"
else
    log "hf CLI not found, using curl"
    for rel in "${missing[@]}"; do
        url="https://huggingface.co/$REPO/resolve/$REVISION/$VARIANT/$rel"
        mkdir -p "$DEST/$(dirname "$rel")"
        log "  → $rel"
        # -C - resumes a partial file; retry covers a dropped connection.
        curl -fL --retry 5 --retry-delay 2 -C - --progress-bar \
            "$url" -o "$DEST/$rel"
    done
fi

failed=0
while IFS=$'\t' read -r rel size want; do
    if ! is_good "$DEST/$rel" "$size" "$want"; then
        log "❌ integrity check failed: $rel"
        failed=1
    fi
done <<< "$FILES"
[[ $failed -eq 0 ]] || exit 1

log "✅ downloaded and verified into $DEST"
