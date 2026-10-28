#!/bin/bash
#
# Local CI: the release build, the unit and MLX tests, and the model-backed
# integration tests when the models they need are installed. Stops at the first
# failing step and ends with a pass/fail summary. Full test output is kept in
# .build/ci/.
#
# Environment:
#   ARK_VOICE_INTEGRATION_STT_AUDIO  Audio for the STT tests. When unset, CI
#                                    synthesizes a short clip with the release
#                                    binary and transcribes that.

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"

model_root="$HOME/.ark-voice-cli"
release_binary="$project_root/.build/release/ark-voice"
release_metallib="$project_root/.build/release/mlx.metallib"
log_directory="$project_root/.build/ci"
work_directory="$(mktemp -d)"
mkdir -p "$log_directory"

summary=()
test_metallibs=()
current_step=""
step_detail=""

# MLX looks for mlx.metallib beside the binary that links it, which for a test
# bundle is Contents/MacOS. That directory is meant for code only, so a copy
# left there makes the next rebuild fail to re-sign the bundle. The copies are
# placed after the test build and removed again on exit.
remove_test_metallibs() {
  if ((${#test_metallibs[@]})); then
    rm -f "${test_metallibs[@]}"
  fi
  test_metallibs=()
}

print_summary() {
  echo
  echo "==> Summary"
  local line
  for line in "${summary[@]}"; do
    echo "  $line"
  done
}

finish() {
  local status=$?
  remove_test_metallibs
  rm -rf "$work_directory"
  if [[ -n "$current_step" ]]; then
    summary+=("FAIL  $current_step${step_detail:+ — $step_detail}")
  fi
  print_summary
  echo
  if ((status == 0)); then
    echo "CI passed."
  else
    echo "CI failed${current_step:+ at: $current_step}."
  fi
  exit "$status"
}
trap finish EXIT

# Runs one step with errexit still in force, so the first failing command ends
# the run and the EXIT trap reports the step that was in progress.
run_step() {
  current_step="$1"
  shift
  echo
  echo "==> $current_step"
  local started=$SECONDS
  "$@"
  summary+=("PASS  $current_step ($((SECONDS - started))s)${step_detail:+ — $step_detail}")
  current_step=""
  step_detail=""
}

skip_step() {
  echo
  echo "==> $1"
  echo "Skipped: $2"
  summary+=("SKIP  $1 — $2")
}

# Runs `swift test` against the already-built tests, keeping a log and
# summarizing the counts Swift Testing reports.
swift_test() {
  local log="$log_directory/$1.log"
  shift
  local status=0
  swift test --skip-build "$@" 2>&1 | tee "$log" || status=$?
  local total skipped failed
  total="$(sed -nE 's/.*Test run with ([0-9]+) tests? .*/\1/p' "$log" | awk '{ n += $1 } END { print n + 0 }')"
  skipped="$(grep -c '➜ Test' "$log" || true)"
  failed="$(grep -c '✘ Test .* failed' "$log" || true)"
  step_detail="$total tests, $failed failed, $skipped skipped; log: ${log#"$project_root"/}"
  return "$status"
}

model_installed() {
  grep -q "^$1 \[downloaded\]" "$work_directory/models.txt"
}

build_tests() {
  remove_test_metallibs
  rm -f "$debug_bin"/*.xctest/Contents/MacOS/mlx.metallib
  swift build --build-tests
}

package_test_metallib() {
  local bundle destination
  for bundle in "$debug_bin"/*.xctest; do
    [[ -d "$bundle" ]] || continue
    destination="$bundle/Contents/MacOS/mlx.metallib"
    cp "$release_metallib" "$destination"
    test_metallibs+=("$destination")
  done
  if ((${#test_metallibs[@]} == 0)); then
    echo "error: no test bundles found under $debug_bin" >&2
    return 1
  fi
  # The Qwen recognizer tests point their session at this copy.
  cp "$release_metallib" "$debug_bin/mlx.metallib"
  echo "Copied mlx.metallib into ${#test_metallibs[@]} test bundles."
}

synthesize_stt_sample() {
  "$release_binary" tts "This is a short recording for the local test run." -o "$stt_audio" >/dev/null
  echo "Synthesized $stt_audio"
}

unit_tests() {
  local -x ARK_VOICE_TEST_MLX=1
  swift_test unit
}

integration_tests() {
  local -x ARK_VOICE_TEST_MLX=1
  local -x ARK_VOICE_INTEGRATION_BINARY="$release_binary"
  local -x ARK_VOICE_INTEGRATION_STT_AUDIO="$stt_audio"
  swift_test integration --filter IntegrationTests
}

recognizer_tests() {
  local -x ARK_VOICE_TEST_MLX=1
  local -x ARK_VOICE_TEST_MODELS=1
  local -x ARK_VOICE_TEST_METALLIB="$debug_bin/mlx.metallib"
  local -x ARK_VOICE_INTEGRATION_STT_AUDIO="$stt_audio"
  swift_test recognizers --filter 'RecognizerTests|ServerTests'
}

run_step "Release build" ./Scripts/build-release.sh

debug_bin="$(swift build --show-bin-path)"
run_step "Build tests" build_tests
run_step "Package mlx.metallib for tests" package_test_metallib
run_step "Unit and MLX tests" unit_tests

"$release_binary" models >"$work_directory/models.txt"
missing=()
for model in "Parakeet TDT 0.6B v2 INT8" "Chatterbox Turbo 6-bit" "S3TokenizerV2"; do
  model_installed "$model" || missing+=("$model")
done

if ((${#missing[@]})); then
  joined="$(printf '%s, ' "${missing[@]}")"
  skip_step "Integration tests" "missing ${joined%, } in $model_root (run 'ark-voice download')"
  skip_step "Optional recognizer tests" "the default models are not installed"
  exit 0
fi

if [[ -n "${ARK_VOICE_INTEGRATION_STT_AUDIO:-}" ]]; then
  stt_audio="$ARK_VOICE_INTEGRATION_STT_AUDIO"
else
  stt_audio="$work_directory/ci-sample.wav"
  run_step "Synthesize STT sample" synthesize_stt_sample
fi

run_step "Integration tests" integration_tests

if model_installed "Parakeet Ultra (Core ML)" && model_installed "Qwen3-ASR 1.7B 8-bit"; then
  run_step "Optional recognizer tests" recognizer_tests
else
  skip_step "Optional recognizer tests" \
    "needs parakeet-ultra and qwen ('ark-voice download parakeet-ultra', 'ark-voice download qwen')"
fi
