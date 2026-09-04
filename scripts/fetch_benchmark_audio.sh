#!/bin/bash
#
# Fetch a few minutes of LibriSpeech test-clean into ./Audio (gitignored) and build
# a single reference transcript for it.
#
# LibriSpeech (Panayotov et al., 2015) is CC BY 4.0 — freely redistributable with
# attribution — and ships human-verified transcripts, which is what makes it usable
# as a WER ground truth.
#
#   scripts/fetch_benchmark_audio.sh            # default speaker/chapter
#   scripts/fetch_benchmark_audio.sh 1089 134686
#   scripts/fetch_benchmark_audio.sh --multi    # 12 speakers, ~30 min
#
# A single chapter is one speaker reading one book — fine for a smoke test, far too
# narrow to decide PLAN §5.1 on. `--multi` takes the first chapter of each of the
# first N speakers so the WER covers a range of voices.
#
set -euo pipefail

# Byte ordering, so `sort` here matches the tool's Swift string comparison.
export LC_ALL=C

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIO="$ROOT/Audio"
ARCHIVE="$AUDIO/test-clean.tar.gz"

# Published by OpenSLR alongside the archive.
EXPECTED_MD5="32fa31d27d2e1cad72775fee3f4849a9"

log() { printf '%s\n' "$*" >&2; }

mkdir -p "$AUDIO"

fetch_archive() {
    if [[ ! -f "$ARCHIVE" ]] || [[ "$(md5 -q "$ARCHIVE")" != "$EXPECTED_MD5" ]]; then
        log "downloading LibriSpeech test-clean (346 MB)…"
        curl -fL --retry 5 --retry-delay 2 -C - --progress-bar \
            "https://www.openslr.org/resources/12/test-clean.tar.gz" -o "$ARCHIVE"
        actual="$(md5 -q "$ARCHIVE")"
        if [[ "$actual" != "$EXPECTED_MD5" ]]; then
            log "❌ checksum mismatch: got $actual, expected $EXPECTED_MD5"
            exit 1
        fi
    fi
}

# LibriSpeech transcripts are "<utt-id> UPPERCASE WORDS"; drop the id and lowercase
# so the reference is plain prose. WER normalisation strips punctuation anyway.
append_reference() {
    cut -d' ' -f2- "$1" | tr 'A-Z' 'a-z' >> "$2"
}

if [[ "${1:-}" == "--multi" ]]; then
    SPEAKER_LIMIT="${2:-12}"
    OUT="$AUDIO/librispeech-multi"
    fetch_archive

    if [[ ! -d "$AUDIO/LibriSpeech/test-clean" ]] \
        || [[ "$(find "$AUDIO/LibriSpeech/test-clean" -mindepth 1 -maxdepth 1 -type d | wc -l)" -lt "$SPEAKER_LIMIT" ]]; then
        log "extracting full test-clean…"
        tar -xzf "$ARCHIVE" -C "$AUDIO" "LibriSpeech/test-clean"
    fi

    rm -rf "$OUT"
    mkdir -p "$OUT"

    speakers=$(find "$AUDIO/LibriSpeech/test-clean" -mindepth 1 -maxdepth 1 -type d \
        -exec basename {} \; | sort | head -n "$SPEAKER_LIMIT")
    chapters=0
    : > "$OUT/.trans"
    for speaker in $speakers; do
        chapter=$(find "$AUDIO/LibriSpeech/test-clean/$speaker" -mindepth 1 -maxdepth 1 -type d \
            -exec basename {} \; | sort | head -n 1)
        [[ -n "$chapter" ]] || continue
        dir="$AUDIO/LibriSpeech/test-clean/$speaker/$chapter"
        cp "$dir"/*.flac "$OUT/"
        cat "$dir/$speaker-$chapter.trans.txt" >> "$OUT/.trans"
        chapters=$((chapters + 1))
    done

    # 🔴 The reference must be in the exact order the benchmark tool concatenates the
    # audio, which is a lexicographic sort of the flat directory. Speaker-major sorts
    # (numeric vs string) disagree, so drive the order off the copied files themselves
    # and look each utterance id up rather than trusting the walk order.
    : > "$OUT/reference.txt"
    for flac in $(ls "$OUT"/*.flac | sort); do
        id="$(basename "$flac" .flac)"
        line="$(grep -m1 "^$id " "$OUT/.trans")" || { log "❌ no reference for $id"; exit 1; }
        printf '%s\n' "${line#"$id" }" | tr 'A-Z' 'a-z' >> "$OUT/reference.txt"
    done
    rm -f "$OUT/.trans"

    cat > "$OUT/SOURCE.md" <<EOF
LibriSpeech test-clean — first chapter of each of the first $SPEAKER_LIMIT speakers ($chapters chapters).
Corpus: Panayotov, Chen, Povey, Khudanpur (2015), https://www.openslr.org/12/
License: CC BY 4.0. Audio and reference transcript are redistributable with attribution.
Not committed to git — regenerate with scripts/fetch_benchmark_audio.sh --multi $SPEAKER_LIMIT
EOF
else
    SPEAKER="${1:-1089}"
    CHAPTER="${2:-134686}"
    EXTRACTED="$AUDIO/LibriSpeech/test-clean/$SPEAKER/$CHAPTER"
    OUT="$AUDIO/librispeech-$SPEAKER-$CHAPTER"
    fetch_archive

    if [[ ! -d "$EXTRACTED" ]]; then
        log "extracting ${SPEAKER}/${CHAPTER}"
        tar -xzf "$ARCHIVE" -C "$AUDIO" "LibriSpeech/test-clean/$SPEAKER/$CHAPTER"
    fi

    TRANS="$EXTRACTED/$SPEAKER-$CHAPTER.trans.txt"
    [[ -f "$TRANS" ]] || { log "❌ no transcript at $TRANS"; exit 1; }

    rm -rf "$OUT"
    mkdir -p "$OUT"
    cp "$EXTRACTED"/*.flac "$OUT/"
    : > "$OUT/reference.txt"
    append_reference "$TRANS" "$OUT/reference.txt"

    cat > "$OUT/SOURCE.md" <<EOF
LibriSpeech test-clean, speaker $SPEAKER, chapter $CHAPTER.
Corpus: Panayotov, Chen, Povey, Khudanpur (2015), https://www.openslr.org/12/
License: CC BY 4.0. Audio and reference transcript are redistributable with attribution.
Not committed to git — regenerate with scripts/fetch_benchmark_audio.sh $SPEAKER $CHAPTER
EOF
fi

count=$(ls "$OUT"/*.flac | wc -l | tr -d ' ')
log "✅ $count utterances in $OUT"
log "   reference: $OUT/reference.txt ($(wc -w < "$OUT/reference.txt" | tr -d ' ') words)"
