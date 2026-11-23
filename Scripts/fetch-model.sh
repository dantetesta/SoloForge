#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../Models/GuitarSeparation"
model=HTDemucs_6S_Split_F16.mlpackage
revision=f7f11bf599d5aa5fd5af0355ea7bffec72c0b7b8
checks="$PWD/SHA256SUMS"
if [[ -d "$model" ]]; then
    (cd "$model" && shasum -a 256 -c "$checks")
    exit
fi
stage=$(mktemp -d "$PWD/.download.XXXXXX")
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/$model/Data/com.apple.CoreML/weights"
while read -r digest asset; do
    curl --fail --silent --show-error --location --retry 3 --proto '=https' --proto-redir '=https' \
        "https://huggingface.co/GOVO/HTDemucs_6S_CoreML/resolve/$revision/$model/$asset" \
        -o "$stage/$model/$asset"
done < "$checks"
(cd "$stage/$model" && shasum -a 256 -c "$checks")
mv "$stage/$model" "$model"
