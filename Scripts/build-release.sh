#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"

swift build -c release

mlx_version="0.31.6"
framework_url="https://github.com/ml-explore/mlx-swift/releases/download/$mlx_version/Cmlx.xcframework.zip"
framework_sha256="a202bf1dcfe1e64404adabfeb5eb363332e3a6221d18e4289ca0663fa3ab86c9"
artifact_directory="$project_root/.build/artifacts/ark-voice"
framework_archive="$artifact_directory/Cmlx.xcframework-$mlx_version.zip"
output_directory="$project_root/.build/release"

mkdir -p "$artifact_directory"

archive_is_valid() {
  [[ -f "$1" ]] && [[ "$(shasum -a 256 "$1" | awk '{print $1}')" == "$framework_sha256" ]]
}

if [[ -f "$framework_archive" ]] && ! archive_is_valid "$framework_archive"; then
  echo "Discarding invalid cached archive: $framework_archive" >&2
  rm -f "$framework_archive"
fi

if [[ ! -f "$framework_archive" ]]; then
  echo "Downloading the pinned MLX $mlx_version Metal runtime..."
  temporary_archive="$(mktemp "$artifact_directory/.Cmlx.xcframework-$mlx_version.XXXXXX")"
  cleanup_download() {
    rm -f "$temporary_archive"
  }
  trap cleanup_download EXIT

  curl -fL --retry 3 --remove-on-error --progress-bar "$framework_url" -o "$temporary_archive"
  if ! archive_is_valid "$temporary_archive"; then
    actual_sha256="$(shasum -a 256 "$temporary_archive" | awk '{print $1}')"
    echo "error: checksum mismatch for downloaded MLX runtime" >&2
    echo "Expected: $framework_sha256" >&2
    echo "Actual:   $actual_sha256" >&2
    exit 1
  fi
  mv "$temporary_archive" "$framework_archive"
  trap - EXIT
fi

extraction_directory="$(mktemp -d "${TMPDIR:-/tmp}/ark-voice-cmlx.XXXXXX")"
cleanup() {
  rm -rf "$extraction_directory"
}
trap cleanup EXIT

framework_resource="Cmlx.xcframework/macos-arm64_x86_64/Cmlx.framework/Versions/A/Resources/default.metallib"
unzip -q "$framework_archive" "$framework_resource" -d "$extraction_directory"
cp "$extraction_directory/$framework_resource" "$output_directory/mlx.metallib"

echo "Built:"
echo "  $output_directory/ark-voice"
echo "  $output_directory/mlx.metallib"
echo "Keep these two files in the same directory."
