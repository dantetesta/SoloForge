#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
./Scripts/swift-local.sh build -c release --product Workbench
binary="$(./Scripts/swift-local.sh build -c release --show-bin-path)/Workbench"
stage="$(mktemp -d "$PWD/.build-local/package.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
bundle="$stage/SoloForge.app"
contents="$bundle/Contents"
output_dir="${SOLOFORGE_DIST_DIR:-$PWD/dist}"
mkdir -p "$contents/MacOS" "$contents/Resources" "$stage/AppIcon.iconset" "$output_dir"
install -m 0755 "$binary" "$contents/MacOS/Workbench"
install -m 0644 Branding/Wordmark.png "$contents/Resources/Wordmark.png"
model_src="Models/BasicPitch"
model_dst="$contents/Resources/BasicPitch"
mkdir -p "$model_dst/nmp.mlpackage/Data/com.apple.CoreML/weights"
for asset in LICENSE.txt nmp.mlpackage/Manifest.json nmp.mlpackage/Data/com.apple.CoreML/model.mlmodel nmp.mlpackage/Data/com.apple.CoreML/weights/weight.bin; do
    install -m 0644 "$model_src/$asset" "$model_dst/$asset"
done
stem="HTDemucs_6S_Split_F16.mlpackage"
stem_dst="$contents/Resources/GuitarSeparation"
mkdir -p "$stem_dst/$stem/Data/com.apple.CoreML/weights"
for asset in LICENSE.txt "$stem/Manifest.json" "$stem/Data/com.apple.CoreML/model.mlmodel" "$stem/Data/com.apple.CoreML/weights/weight.bin"; do
    install -m 0644 "Models/GuitarSeparation/$asset" "$stem_dst/$asset"
done
for kind in Electric Acoustic; do
    mkdir -p "$contents/Resources/Instruments/$kind"
    for sample in Instruments/"$kind"/*.wav; do
        install -m 0644 "$sample" "$contents/Resources/Instruments/$kind/$(basename "$sample")"
    done
done
install -m 0644 Instruments/NOTICE.txt "$contents/Resources/Instruments/NOTICE.txt"
for side in 16 32 128 256 512; do
    sips -z "$side" "$side" Branding/AppIcon.png --out "$stage/AppIcon.iconset/icon_${side}x${side}.png" >/dev/null
    sips -z "$((side * 2))" "$((side * 2))" Branding/AppIcon.png --out "$stage/AppIcon.iconset/icon_${side}x${side}@2x.png" >/dev/null
done
CLANG_MODULE_CACHE_PATH="$PWD/.build-local/modules" swift Scripts/icon.swift "$stage/AppIcon.iconset" "$contents/Resources/AppIcon.icns"
install -m 0644 Branding/Info.plist "$contents/Info.plist"
plutil -lint "$contents/Info.plist"

codesign --force --sign - "$bundle"
codesign --verify --strict "$bundle"
destination="$output_dir/SoloForge.app"
replacement="$output_dir/.Previous.app"
if [[ -f "$destination/Contents/MacOS/Workbench" ]] && /usr/sbin/lsof -t "$destination/Contents/MacOS/Workbench" >/dev/null 2>&1; then
    # Keep the executable and its signing resources available to the live process.
    pending="$(mktemp -d "$output_dir/atualizacao.XXXXXX")"
    mv "$bundle" "$pending/SoloForge.app"
    printf 'O SoloForge está em uso. Novo aplicativo em %s/SoloForge.app.\n' "$pending"
    exit 75
fi
if [[ -e "$replacement" ]]; then
    printf 'Existe um backup de build em %s.\n' "$replacement" >&2
    exit 1
fi
if [[ -d "$destination" ]]; then mv "$destination" "$replacement"; fi
if mv "$bundle" "$destination"; then
    if [[ -d "$replacement" ]]; then rm -rf "$replacement"; fi
else
    if [[ -d "$replacement" ]]; then mv "$replacement" "$destination"; fi
    exit 1
fi
find "$destination/Contents" -type f -print
file "$destination/Contents/MacOS/Workbench"
