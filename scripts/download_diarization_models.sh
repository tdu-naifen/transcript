#!/bin/bash
#
# Fetch the Sortformer palettized diarization model + CAM++ voiceprint embedder CoreML
# bundles into ./Models (gitignored). Dev-time only, mirrors download_models.sh —
# runtime stays 🔴 OFFLINE ONLY (PLAN decision: app code never calls download*).
#
# Idempotent: every file is verified against the sha256 the Hugging Face tree API
# reports for its LFS object.
#
#   scripts/download_diarization_models.sh                    # fastV2_1 palettized (default)
#   scripts/download_diarization_models.sh balancedV2_1        # other Sortformer variant
#   VERIFY_ONLY=1 scripts/download_diarization_models.sh       # check an existing copy
#
# 🔴 Only the palettized precision is ever fetched here. The fp16 high-context head
# needs ~2.4GB RAM and can hang ANE compilation on <8GB devices (FluidAudio issue #726);
# palettized is ~330MB for +0.9pp DER, the right trade on iPhone. Never add an fp16 path
# for a high-context variant to this script.
#
set -euo pipefail

SORTFORMER_REPO="FluidInference/diar-streaming-sortformer-coreml"
CAMPPLUS_REPO="FluidInference/campplus-coreml"
SORTFORMER_REVISION="${SORTFORMER_MODEL_REVISION:-main}"
# CAM++ is Beta in FluidAudio (API/artifacts/accuracy may change) — pinned to a known
# commit rather than a moving branch, so a future upload can't silently change the
# embedding space out from under stored voiceprints. Resolved with:
#   curl https://huggingface.co/api/models/FluidInference/campplus-coreml/revision/main
# Bump deliberately (and re-embed existing voiceprints) via CAMPPLUS_MODEL_REVISION.
CAMPPLUS_REVISION="${CAMPPLUS_MODEL_REVISION:-daa02e7cc1b98e4f3f6fec94db9d91f3b0cf4120}"

# Maps our CLI name to the .mlmodelc basename FluidAudio's
# `ModelNames.Sortformer.Variant.fileName(precision:)` expects.
sortformer_model_name() {
    case "$1" in
        fastV2_1) echo "Sortformer_v2.1" ;;
        balancedV2_1) echo "SortformerNvidiaLow_v2.1" ;;
        *)
            printf 'error: unknown Sortformer variant '\''%s'\'' (use fastV2_1 or balancedV2_1)\n' "$1" >&2
            exit 1
            ;;
    esac
}

VARIANT_NAME="${1:-fastV2_1}"
MODEL_BASENAME="$(sortformer_model_name "$VARIANT_NAME")"
SORTFORMER_VARIANT_PATH="v3/palettized/$MODEL_BASENAME.mlmodelc"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SORTFORMER_DEST="$ROOT/Models/sortformer-diarization"
CAMPPLUS_DEST="$ROOT/Models/campplus-embedder"
TREE_DIR="$(mktemp -d -t diarization-tree)"

log() { printf '%s\n' "$*" >&2; }

LOCK="$ROOT/Models/.download.lock"
mkdir -p "$ROOT/Models"
if ! mkdir "$LOCK" 2>/dev/null; then
    log "error: another download is already running (remove $LOCK if stale)"
    exit 1
fi
trap 'rm -rf "$TREE_DIR"; rmdir "$LOCK" 2>/dev/null || true' EXIT

sha_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

# A file is "good" when it exists and either matches the published sha256 or — for the
# small non-LFS files HF serves without an oid — matches the byte count.
is_good() {
    local file="$1" size="$2" want="$3"
    [[ -f "$file" ]] || return 1
    local have
    have="$(stat -f%z "$file")"
    [[ "$have" == "$size" ]] || return 1
    [[ -n "$want" ]] || return 0
    [[ "$(sha_of "$file")" == "$want" ]]
}

# Fetches every file under path prefix $2 (or the whole repo when "") in HF repo $1
# into destination $3, verifying by the tree API's reported size/sha256.
fetch_hf_prefix() {
    local repo="$1" revision="$2" prefix="$3" dest="$4"
    local tree_json="$TREE_DIR/$(echo "$repo/$prefix" | tr '/' '_').json"

    local api="https://huggingface.co/api/models/$repo/tree/$revision"
    [[ -n "$prefix" ]] && api="$api/$prefix"
    api="$api?recursive=1"
    log "repo     $repo@$revision"
    log "prefix   ${prefix:-<root>}"
    log "dest     $dest"
    if ! curl -fsSL --retry 3 --retry-delay 2 -m 120 "$api" -o "$tree_json"; then
        log "error: cannot reach the Hugging Face tree API for $repo"
        exit 1
    fi

    local files
    files="$(python3 - "$tree_json" "$prefix" <<'PY'
import json, sys
tree = json.load(open(sys.argv[1]))
prefix = sys.argv[2]
strip = (prefix.rstrip("/") + "/") if prefix else ""
rows = []
for entry in tree:
    if entry.get("type") != "file":
        continue
    path = entry["path"]
    if strip and not path.startswith(strip):
        continue
    lfs = entry.get("lfs") or {}
    rows.append("\t".join([
        path[len(strip):],
        str(lfs.get("size") or entry.get("size") or 0),
        lfs.get("oid") or "",
    ]))
if not rows:
    sys.exit("no files found — is the prefix correct?")
print("\n".join(sorted(rows)))
PY
)"

    local total_bytes=0
    while IFS=$'\t' read -r _ size _; do
        total_bytes=$((total_bytes + size))
    done <<< "$files"
    log "$(wc -l <<< "$files" | tr -d ' ') files, $((total_bytes / 1000000)) MB"

    local missing=()
    while IFS=$'\t' read -r rel size want; do
        is_good "$dest/$rel" "$size" "$want" || missing+=("$rel")
    done <<< "$files"

    if [[ ${#missing[@]} -eq 0 ]]; then
        log "✅ all files present and verified"
        return 0
    fi

    if [[ -n "${VERIFY_ONLY:-}" ]]; then
        log "❌ ${#missing[@]} file(s) missing or corrupt:"
        printf '   %s\n' "${missing[@]}" >&2
        return 1
    fi

    log "${#missing[@]} file(s) to fetch"
    if command -v hf >/dev/null 2>&1; then
        log "using hf CLI"
        local patterns=() hf_tmp="$dest.hf"
        for rel in "${missing[@]}"; do
            patterns+=(--include "${prefix:+$prefix/}$rel")
        done
        hf download "$repo" --revision "$revision" --local-dir "$hf_tmp" "${patterns[@]}" >&2
        mkdir -p "$dest"
        for rel in "${missing[@]}"; do
            mkdir -p "$dest/$(dirname "$rel")"
            mv -f "$hf_tmp/${prefix:+$prefix/}$rel" "$dest/$rel"
        done
        rm -rf "$hf_tmp"
    else
        log "hf CLI not found, using curl"
        for rel in "${missing[@]}"; do
            local url="https://huggingface.co/$repo/resolve/$revision/${prefix:+$prefix/}$rel"
            mkdir -p "$dest/$(dirname "$rel")"
            log "  → $rel"
            curl -fL --retry 5 --retry-delay 2 -C - --progress-bar "$url" -o "$dest/$rel"
        done
    fi

    local failed=0
    while IFS=$'\t' read -r rel size want; do
        if ! is_good "$dest/$rel" "$size" "$want"; then
            log "❌ integrity check failed: $rel"
            failed=1
        fi
    done <<< "$files"
    [[ $failed -eq 0 ]] || return 1
    echo "$revision" > "$dest.revision"
    log "✅ downloaded and verified into $dest (pinned $repo@$revision)"
}

fetch_hf_prefix "$SORTFORMER_REPO" "$SORTFORMER_REVISION" "$SORTFORMER_VARIANT_PATH" \
    "$SORTFORMER_DEST/$SORTFORMER_VARIANT_PATH"
fetch_hf_prefix "$CAMPPLUS_REPO" "$CAMPPLUS_REVISION" "" "$CAMPPLUS_DEST"
