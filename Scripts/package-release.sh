#!/bin/bash
#
# Builds, signs, notarizes, and packages a release into
# dist/ark-voice-<version>-macos-arm64.zip, with a .sha256 beside it.
#
# The version comes from `arkVoiceVersion` in Sources/ArkVoiceCLI/App.swift.
# Run from a clean checkout of the commit being released; ./Scripts/ci.sh first.
#
# Environment:
#   ARK_VOICE_SIGNING_IDENTITY  Developer ID Application identity to sign with
#   ARK_VOICE_NOTARY_PROFILE    notarytool keychain profile (orkestrator-notary)
#
# A bare command-line binary cannot have a notarization ticket stapled to it,
# and neither can a zip. Gatekeeper fetches the ticket from Apple on the first
# run of a downloaded copy instead, so that first run needs a network connection.

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"

identity="${ARK_VOICE_SIGNING_IDENTITY:-Developer ID Application: Digital Insight Consulting Ltd. (QWD87G9T3P)}"
notary_profile="${ARK_VOICE_NOTARY_PROFILE:-orkestrator-notary}"
bundle_identifier="com.ark-voice.cli"

fail() {
  echo "error: $*" >&2
  exit 1
}

version="$(sed -nE 's/^let arkVoiceVersion = "([^"]+)"$/\1/p' Sources/ArkVoiceCLI/App.swift)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]] \
  || fail "could not read a version from arkVoiceVersion in Sources/ArkVoiceCLI/App.swift"

if [[ -n "$(git status --porcelain)" ]]; then
  git status --short >&2
  fail "the working tree is not clean; commit or remove the changes above first"
fi
commit="$(git rev-parse --short HEAD)"

package_name="ark-voice-$version-macos-arm64"
dist_directory="$project_root/dist"
zip_path="$dist_directory/$package_name.zip"
checksum_path="$zip_path.sha256"

release_directory="$project_root/.build/release"
# Swift 6.2+ back-deploys Span through this library. The binary links it from
# @rpath, which resolves to /usr/lib/swift on macOS 26 and later and to the copy
# beside the binary (@loader_path) on macOS 14 and 15, where the OS lacks it.
span_library_name="libswiftCompatibilitySpan.dylib"

work_directory="$(mktemp -d)"
cleanup() {
  if [[ -n "${server_pid:-}" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$work_directory"
}
trap cleanup EXIT

stage="$work_directory/stage/$package_name"

echo "==> Packaging ark-voice $version ($commit)"

echo
echo "==> Build"
./Scripts/build-release.sh

[[ "$(lipo -archs "$release_directory/ark-voice")" == "arm64" ]] \
  || fail "expected an arm64-only executable, found: $(lipo -archs "$release_directory/ark-voice")"
built_version="$("$release_directory/ark-voice" --version)"
[[ "$built_version" == "ark-voice $version" ]] \
  || fail "the built executable reports '$built_version', expected 'ark-voice $version'"

span_library_source="$(
  xcrun --find swift | sed 's#/bin/swift$##'
)/lib/swift-6.2/macosx/$span_library_name"
if otool -L "$release_directory/ark-voice" | grep -q "@rpath/$span_library_name"; then
  [[ -f "$span_library_source" ]] || fail "the toolchain does not provide $span_library_source"
  ship_span_library=1
else
  ship_span_library=0
fi

echo
echo "==> Stage"
mkdir -p "$stage"
cp "$release_directory/ark-voice" "$stage/ark-voice"
cp "$release_directory/mlx.metallib" "$stage/mlx.metallib"
cp THIRD_PARTY_NOTICES.md "$stage/THIRD_PARTY_NOTICES.md"
if ((ship_span_library)); then
  lipo -thin arm64 "$span_library_source" -output "$stage/$span_library_name" 2>/dev/null \
    || cp "$span_library_source" "$stage/$span_library_name"
fi
ls -l "$stage"

echo
echo "==> Sign"
# mlx.metallib is not signed. It is not Mach-O code: dyld never loads it, so
# library validation does not apply, notarization only checks Mach-O files, and
# a signature on a plain file lives in extended attributes that a zip carries
# only as AppleDouble side files. Metal reads it as data.
sign() {
  if ! codesign --force --sign "$identity" --options runtime --timestamp "$@"; then
    echo "codesign failed. If it reported errSecInternalComponent, the login keychain is" >&2
    echo "locked in this session: unlock it yourself and run this script again." >&2
    exit 1
  fi
}
if ((ship_span_library)); then
  sign "$stage/$span_library_name"
fi
sign --identifier "$bundle_identifier" "$stage/ark-voice"

for code in "$stage/ark-voice" "$stage/$span_library_name"; do
  [[ -f "$code" ]] || continue
  codesign --verify --strict --verbose=2 "$code"
  details="$(codesign --display --verbose=4 "$code" 2>&1)"
  grep -q "flags=.*runtime" <<<"$details" || fail "$code is not signed with the hardened runtime"
  grep -q "^Timestamp=" <<<"$details" || fail "$code has no secure timestamp"
done

echo
echo "==> Smoke test the signed binary"
# Runs from a directory holding only the release files, so nothing can be
# picked up from .build. Needs the default models in ~/.ark-voice-cli.
smoke_directory="$work_directory/smoke"
mkdir -p "$smoke_directory"
cp -R "$stage/." "$smoke_directory/"
binary="$smoke_directory/ark-voice"
smoke_output="$work_directory/smoke-output"
mkdir -p "$smoke_output"

"$binary" models >"$work_directory/models.txt"
for model in "Parakeet TDT 0.6B v2 INT8" "Chatterbox Turbo 6-bit" "S3TokenizerV2"; do
  grep -q "^$model \[downloaded\]" "$work_directory/models.txt" \
    || fail "the smoke test needs $model; run 'ark-voice download' first"
done

# Recognition is not exact, so a transcript passes when it has any of the key
# words of the sentence that was spoken.
check_transcript() {
  local label="$1" words="$2" transcript="$3"
  echo "  $label: $transcript"
  grep -qiE "$words" <<<"$transcript" || fail "$label heard none of: $words"
}

sentence="This signed build speaks and listens."
sentence_words="signed|build|speaks|listens"
"$binary" tts "$sentence" -o "$smoke_output/speech.wav" >/dev/null
[[ -s "$smoke_output/speech.wav" ]] || fail "tts wrote no audio"
"$binary" tts "$sentence" -o "$smoke_output/speech.m4a" >/dev/null
[[ -s "$smoke_output/speech.m4a" ]] || fail "tts wrote no M4A audio"
echo "  tts: wrote WAV and M4A"
check_transcript "stt" "$sentence_words" "$("$binary" stt "$smoke_output/speech.wav")"
check_transcript "stt from M4A on stdin" "$sentence_words" "$("$binary" stt - <"$smoke_output/speech.m4a")"
for optional in "Parakeet Ultra (Core ML):parakeet-ultra" "Qwen3-ASR 1.7B 8-bit:qwen"; do
  if grep -q "^${optional%%:*} \[downloaded\]" "$work_directory/models.txt"; then
    check_transcript "stt --model ${optional##*:}" "$sentence_words" \
      "$("$binary" stt "$smoke_output/speech.wav" --model "${optional##*:}" 2>>"$smoke_output/stt.log")"
  else
    echo "  stt --model ${optional##*:}: skipped, model not installed"
  fi
done

socket="$work_directory/av.sock"
"$binary" serve --socket "$socket" --idle-unload off --idle-exit off 2>"$smoke_output/serve.log" &
server_pid=$!
for _ in $(seq 1 200); do
  [[ -S "$socket" ]] && break
  sleep 0.05
done
[[ -S "$socket" ]] || fail "serve did not create its socket; see the log above"
"$binary" client tts "The server answers every request quickly." \
  -o "$smoke_output/client.wav" --socket "$socket" >/dev/null
check_transcript "client stt" "server|answers|request|quickly" \
  "$("$binary" client stt "$smoke_output/client.wav" --socket "$socket")"
"$binary" client status --socket "$socket" | grep -q "synthesis model loaded: true" \
  || fail "the daemon did not keep its synthesis model loaded"
echo "  serve/client: round trip passed"
kill "$server_pid"
wait "$server_pid" 2>/dev/null || true
server_pid=""

echo
echo "==> Zip"
mkdir -p "$dist_directory"
rm -f "$zip_path" "$checksum_path"
# Extended attributes (such as com.apple.provenance) would otherwise be stored
# as AppleDouble ._ files that `unzip` leaves beside each file. The signatures
# are embedded in the Mach-O files and do not need them.
ditto -c -k --norsrc --noextattr --noacl --keepParent "$stage" "$zip_path"

echo
echo "==> Notarize"
notary_result="$work_directory/notary.json"
if ! xcrun notarytool submit "$zip_path" --keychain-profile "$notary_profile" --wait \
  --output-format json >"$notary_result"; then
  cat "$notary_result" >&2 || true
  echo >&2
  echo "notarytool failed. A 401 means the stored app-specific password is no longer valid," >&2
  echo "and 'keychainLocked' means the login keychain is locked; both need you to fix them." >&2
  rm -f "$zip_path"
  exit 1
fi
submission_id="$(plutil -extract id raw -o - "$notary_result")"
submission_status="$(plutil -extract status raw -o - "$notary_result")"
echo "Submission $submission_id: $submission_status"
if [[ "$submission_status" != "Accepted" ]]; then
  xcrun notarytool log "$submission_id" --keychain-profile "$notary_profile" >&2 || true
  rm -f "$zip_path"
  fail "notarization was not accepted"
fi

echo
echo "==> Verify the notarized zip"
# Extract as a download would arrive: quarantined, so the checks below exercise
# Gatekeeper's online ticket lookup.
verify_directory="$work_directory/verify"
mkdir -p "$verify_directory"
ditto -x -k "$zip_path" "$verify_directory"
extracted="$verify_directory/$package_name"
quarantine="0081;$(printf '%x' "$(date +%s)");ark-voice-release;"
find "$extracted" -type f -exec xattr -w com.apple.quarantine "$quarantine" {} +

# `spctl --type execute` assesses app bundles and rejects any bare executable as
# "not an app", so each Mach-O file is assessed as `--type install` instead,
# which reports whether Gatekeeper accepts it as notarized Developer ID code.
for code in "$extracted/ark-voice" "$extracted/$span_library_name"; do
  [[ -f "$code" ]] || continue
  codesign --verify --strict --check-notarization --verbose=2 "$code"
  assessment="$(spctl --assess --type install --verbose=4 "$code" 2>&1)"
  echo "$assessment"
  grep -q "source=Notarized Developer ID" <<<"$assessment" \
    || fail "Gatekeeper did not accept $code as notarized"
done
[[ "$("$extracted/ark-voice" --version)" == "ark-voice $version" ]] \
  || fail "the quarantined executable did not run"

(cd "$dist_directory" && shasum -a 256 "$package_name.zip" >"$package_name.zip.sha256")

echo
echo "==> Release artifact"
echo "  version:    $version ($commit)"
echo "  zip:        ${zip_path#"$project_root"/}"
echo "  sha256:     $(awk '{print $1}' "$checksum_path")"
echo "  size:       $(stat -f %z "$zip_path") bytes"
echo "  submission: $submission_id ($submission_status)"
echo
echo "The ticket is not stapled (a bare binary cannot hold one); Gatekeeper checks it"
echo "online the first time a downloaded copy runs."
