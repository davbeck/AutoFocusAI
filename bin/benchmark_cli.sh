#!/bin/zsh

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
	echo "usage: $0 <input-video> [output-video]" >&2
	exit 64
fi

project="AutoFocusAI.xcodeproj"
scheme="AutoFocusAICLI"
input_video=$1
output_video=${2:-/tmp/${${input_video:t}:r}-benchmark.mov}

if [[ ! -f "$input_video" ]]; then
	echo "input video not found: $input_video" >&2
	exit 66
fi

echo "Building $scheme..."
xcodebuild build -project "$project" -scheme "$scheme" >/dev/null

build_settings=$(xcodebuild -project "$project" -scheme "$scheme" -showBuildSettings)
target_build_dir=$(printf '%s\n' "$build_settings" | awk -F ' = ' '/ TARGET_BUILD_DIR = / { print $2; exit }')
executable_path=$(printf '%s\n' "$build_settings" | awk -F ' = ' '/ EXECUTABLE_PATH = / { print $2; exit }')

if [[ -z "$target_build_dir" || -z "$executable_path" ]]; then
	echo "unable to locate built CLI binary" >&2
	exit 70
fi

cli_binary="$target_build_dir/$executable_path"

echo "Benchmarking:"
echo "  input:  $input_video"
echo "  output: $output_video"
/usr/bin/time -p "$cli_binary" "$input_video" "$output_video"
