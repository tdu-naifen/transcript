#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DEVICE_ID="${TRANSCRIPT_SIMULATOR_ID:-48540309-C15F-4F0C-83EF-C0F096D1B542}"
SCRATCH_ROOT="${CLAUDE_JOB_DIR:+${CLAUDE_JOB_DIR}/tmp}"
SCRATCH_ROOT="${SCRATCH_ROOT:-${TMPDIR:-/tmp}}"
DERIVED_DATA="${TRANSCRIPT_DERIVED_DATA:-${SCRATCH_ROOT}/transcript-backend-verification-${UID}}"

usage() {
    printf '%s\n' \
        "Usage: $(basename "$0") [--print-command] [xcodebuild arguments...]" \
        "" \
        "Runs TranscriptCore package tests on an iOS Simulator without building the app." \
        "Default simulator: iPhone 17 Pro, iOS 26.4.1 ($DEVICE_ID)" \
        "Override with TRANSCRIPT_SIMULATOR_ID and TRANSCRIPT_DERIVED_DATA." \
        "" \
        "Examples:" \
        "  $(basename "$0")" \
        "  $(basename "$0") -only-testing:TranscriptCoreTests/BackendBenchmarkTests" \
        "  BACKEND_REAL_CAMPLUS=1 $(basename "$0") -only-testing:TranscriptCoreTests/VoiceprintRuntimeTests" \
        "  BACKEND_BENCHMARK_VECTOR_COUNT=10000 $(basename "$0") -only-testing:TranscriptCoreTests/BackendBenchmarkTests" \
        "  BACKEND_BENCHMARK_MATCHER_COUNT=10000 $(basename "$0") -only-testing:TranscriptCoreTests/BackendBenchmarkTests" \
        "  BACKEND_BENCHMARK_MEETING_COUNT=10 BACKEND_BENCHMARK_UTTERANCES_PER_MEETING=72 $(basename "$0") -only-testing:TranscriptCoreTests/BackendBenchmarkTests" \
        "  BACKEND_BENCHMARK_MEETING_COUNT=3650 BACKEND_BENCHMARK_UTTERANCES_PER_MEETING=720 $(basename "$0") -only-testing:TranscriptCoreTests/BackendBenchmarkTests"
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi

PRINT_COMMAND=false
if [[ "${1:-}" == "--print-command" ]]; then
    PRINT_COMMAND=true
    shift
fi

# xcodebuild forwards TEST_RUNNER_* variables into the test process with that prefix removed.
runner_environment=(env)
for name in BACKEND_BENCHMARK_VECTOR_COUNT BACKEND_BENCHMARK_MATCHER_COUNT \
    BACKEND_BENCHMARK_VECTOR_DIMENSION BACKEND_BENCHMARK_ITERATIONS \
    BACKEND_BENCHMARK_MEETING_COUNT BACKEND_BENCHMARK_UTTERANCES_PER_MEETING \
    BACKEND_REAL_CAMPLUS; do
    if [[ -n "${!name:-}" ]]; then
        runner_environment+=("TEST_RUNNER_${name}=${!name}")
    fi
done

command=(
    xcodebuild
    -project "$ROOT/Transcript.xcodeproj"
    -scheme TranscriptCore
    -destination "platform=iOS Simulator,id=$DEVICE_ID"
    -derivedDataPath "$DERIVED_DATA"
    test
)
# Do not union a broad default selection with a caller's focused suite selection.
HAS_TEST_SELECTION=false
for argument in "$@"; do
    if [[ "$argument" == -only-testing:* ]]; then HAS_TEST_SELECTION=true; fi
done
if [[ "$HAS_TEST_SELECTION" == false ]]; then command+=(-only-testing:TranscriptCoreTests); fi
command+=("$@")

if [[ "$PRINT_COMMAND" == true ]]; then
    printf '%q ' "${runner_environment[@]}" "${command[@]}"
    printf '\n'
    exit 0
fi

if ! xcrun simctl list devices available | grep -Fq "$DEVICE_ID"; then
    printf 'Simulator %s is not available. Set TRANSCRIPT_SIMULATOR_ID to an available iOS Simulator UUID.\n' "$DEVICE_ID" >&2
    exit 2
fi

# Provision only opted-in real inference, into a unique directory inside this Simulator.
if [[ -n "${BACKEND_REAL_CAMPLUS:-}" ]]; then
    if [[ "$BACKEND_REAL_CAMPLUS" != 1 ]]; then
        printf 'BACKEND_REAL_CAMPLUS must be 1.\n' >&2
        exit 2
    fi
    MODEL_SOURCE="$ROOT/Models/campplus-embedder"
    AUDIO_SOURCE="$ROOT/Audio/librispeech-multi"
    for file in \
        "$MODEL_SOURCE/CamPlusPreprocessor.mlmodelc/coremldata.bin" \
        "$MODEL_SOURCE/CamPlusPlus.mlmodelc/coremldata.bin" \
        "$AUDIO_SOURCE/1089-134686-0000.flac" \
        "$AUDIO_SOURCE/1089-134686-0002.flac" \
        "$AUDIO_SOURCE/1188-133604-0000.flac"; do
        if [[ ! -s "$file" ]]; then
            printf 'Required real CAM++ asset missing: %s\n' "$file" >&2
            exit 2
        fi
    done
    SIMULATOR_TMP="$HOME/Library/Developer/CoreSimulator/Devices/$DEVICE_ID/data/tmp"
    mkdir -p "$SIMULATOR_TMP"
    REAL_FIXTURE_DIR="$(mktemp -d "$SIMULATOR_TMP/transcript-camplus.XXXXXX")"
    trap 'rm -rf "$REAL_FIXTURE_DIR"' EXIT
    mkdir -p "$REAL_FIXTURE_DIR/models" "$REAL_FIXTURE_DIR/audio"
    cp -R "$MODEL_SOURCE/CamPlusPreprocessor.mlmodelc" "$MODEL_SOURCE/CamPlusPlus.mlmodelc" "$REAL_FIXTURE_DIR/models/"
    for sample in 1089-134686-0000 1089-134686-0002 1188-133604-0000; do
        cp "$AUDIO_SOURCE/$sample.flac" "$REAL_FIXTURE_DIR/audio/"
    done
    runner_environment+=("TEST_RUNNER_BACKEND_REAL_FIXTURE_DIR=$REAL_FIXTURE_DIR")
    printf 'Real CAM++ fixtures: %s\n' "$REAL_FIXTURE_DIR"
fi

mkdir -p "$DERIVED_DATA"
LOG_FILE="$(mktemp "${DERIVED_DATA}/backend-verification.XXXXXX")"
printf 'Verification log: %s\n' "$LOG_FILE"
"${runner_environment[@]}" "${command[@]}" 2>&1 | tee "$LOG_FILE"

# Requested benchmarks must actually execute, not silently pass as disabled tests.
for specification in \
    "BACKEND_BENCHMARK_VECTOR_COUNT:synthetic-cosine-scan" \
    "BACKEND_BENCHMARK_MATCHER_COUNT:voiceprint-matcher" \
    "BACKEND_BENCHMARK_MEETING_COUNT:search-seed" \
    "BACKEND_REAL_CAMPLUS:real-camplus-complete"; do
    name="${specification%%:*}"
    marker="${specification#*:}"
    if [[ -n "${!name:-}" ]] && ! grep -Fq "BENCHMARK name=${marker} " "$LOG_FILE"; then
        printf 'Requested %s=%s but no %s measurement was emitted; check runner forwarding/test selection.\n' \
            "$name" "${!name}" "$marker" >&2
        exit 3
    fi
done
