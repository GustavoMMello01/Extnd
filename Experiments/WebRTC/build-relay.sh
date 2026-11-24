#!/bin/bash
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
if ! command -v go >/dev/null; then
    echo "error: Go 1.25 or later is required to build the bundled WebRTC relay."
    exit 1
fi

export CGO_ENABLED=0 GOOS=darwin
export GOCACHE="${GOCACHE:-$PROJECT_TEMP_DIR/ExtndGoCache}"
relay_build="$PROJECT_TEMP_DIR/ExtndWebRTC"
output="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers/extnd-webrtc"
mkdir -p "$relay_build" "$(dirname "$output")"

cd "$SRCROOT/Experiments/WebRTC"
read -r -a architectures <<< "$ARCHS"
binaries=()
for architecture in "${architectures[@]}"; do
    case "$architecture" in
        arm64) go_arch=arm64 ;;
        x86_64) go_arch=amd64 ;;
        *) echo "error: Unsupported relay architecture: $architecture"; exit 1 ;;
    esac
    binary="$relay_build/extnd-webrtc-$architecture"
    GOARCH="$go_arch" go build -mod=readonly -trimpath -ldflags="-s -w" -o "$binary" .
    binaries+=("$binary")
done

if (( ${#binaries[@]} == 1 )); then
    /bin/cp "${binaries[0]}" "$output"
else
    /usr/bin/lipo -create "${binaries[@]}" -output "$output"
fi

if [[ "${CODE_SIGNING_ALLOWED:-YES}" == YES ]]; then
    /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$output"
fi
