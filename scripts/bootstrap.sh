#!/usr/bin/env bash
# Makes a fresh machine able to build Transcript. Safe to re-run.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

info() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$1"; }

# ---------------------------------------------------------------- xcodegen ---
if command -v xcodegen >/dev/null 2>&1; then
  info "xcodegen present ($(xcodegen --version 2>&1 | tr -d '\n'))"
else
  info "xcodegen missing, installing via Homebrew"
  if ! command -v brew >/dev/null 2>&1; then
    warn "Homebrew not found. Install it from https://brew.sh then re-run."
    exit 1
  fi
  brew install xcodegen
fi

if ! command -v xcrun >/dev/null 2>&1; then
  warn "xcrun not found. Install Xcode and run: sudo xcode-select -s /Applications/Xcode.app"
  exit 1
fi

# ------------------------------------------------- simulator runtime match ---
# Xcode ships an iPhoneOS SDK that expects a specific simulator runtime build.
# When only an older runtime is installed, xcodebuild reports ZERO iOS
# destinations. `simctl runtime match set` points the SDK at what we do have.
apply_runtime_match() {
  local plan
  plan="$(
    /usr/bin/python3 - <<'PY'
import json, subprocess, sys

def simctl(*args):
    out = subprocess.run(["xcrun", "simctl", *args, "-j"],
                         capture_output=True, text=True)
    if out.returncode != 0:
        return {}
    try:
        return json.loads(out.stdout)
    except json.JSONDecodeError:
        return {}

installed = simctl("runtime", "list")
matches = simctl("runtime", "match", "list")

ios_runtimes = [
    r for r in installed.values()
    if r.get("platformIdentifier") == "com.apple.platform.iphonesimulator"
    and r.get("state") == "Ready"
]
installed_builds = {r["build"] for r in ios_runtimes}

def version_key(runtime):
    return tuple(int(p) for p in runtime.get("version", "0").split(".") if p.isdigit())

for key, m in sorted(matches.items()):
    if m.get("platform") != "com.apple.platform.iphoneos":
        continue
    if m.get("defaultBuild") in installed_builds:
        print(f"ok\t{key}\tdefault runtime {m['defaultBuild']} is installed")
        break
    if m.get("userOverriddenBuild") in installed_builds:
        print(f"ok\t{key}\toverride {m['userOverriddenBuild']} already applied")
        break
    if not ios_runtimes:
        print("none\t\tno iOS simulator runtime installed")
        break
    newest = max(ios_runtimes, key=version_key)
    print(f"set\t{key}\t{newest['build']}\t{newest['version']}")
    break
else:
    print("none\t\tno iPhoneOS SDK entry found")
PY
  )"

  local action key arg extra
  IFS=$'\t' read -r action key arg extra <<<"$plan"

  case "$action" in
    ok)
      info "Simulator runtime match: $arg"
      ;;
    set)
      info "Overriding runtime match: $key -> $arg (iOS $extra)"
      xcrun simctl runtime match set "$key" "$arg"
      info "Undo later with: xcrun simctl runtime match unset $key"
      ;;
    *)
      warn "Could not resolve a simulator runtime (${arg:-unknown})."
      warn "Install one with: xcodebuild -downloadPlatform iOS"
      ;;
  esac
}

apply_runtime_match

# ----------------------------------------------------------- project files ---
info "Generating Transcript.xcodeproj"
xcodegen generate

info "Resolving TranscriptCore package dependencies"
( cd Packages/TranscriptCore && swift package resolve )

cat <<'EOF'

Bootstrap complete. Next steps:

  # After pulling changes or adding/removing Swift files, refresh the ignored project.
  # project.yml recursively includes App, including Views/Components.
  xcodegen generate

  # Build the iOS app
  xcodebuild -project Transcript.xcodeproj -scheme Transcript \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
    -derivedDataPath DerivedData build

  # Build and test the shared package
  cd Packages/TranscriptCore && swift build && swift test

EOF
