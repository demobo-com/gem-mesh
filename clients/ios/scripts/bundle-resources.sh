#!/bin/sh
# Xcode build phase: copies the repo's policy files and the demo files into the app, unchanged, so the app never
# hard-codes rules or tiers (docs/IOS.md §4). policy/ is two levels up from clients/ios.
set -e
repo="${SRCROOT}/../.."
dest="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
[ -f "$repo/policy/tiers.yaml" ] || { echo "error: policy/ not found at $repo/policy" >&2; exit 1; }
mkdir -p "$dest/policy" "$dest/demo"
for f in tiers.yaml rules.yaml models.yaml classifier.txt; do
  cp "$repo/policy/$f" "$dest/policy/$f"
done
if [ -d "$repo/demo/files" ]; then
  cp "$repo/demo/files/"* "$dest/demo/" 2>/dev/null || true
fi
