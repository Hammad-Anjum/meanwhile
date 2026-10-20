#!/bin/sh
# Sets Meanwhile.version from a release tag: scripts/set-version.sh v0.2.0
# Fails unless the tag is a semantic version (vMAJOR.MINOR.PATCH, optional -prerelease).
set -eu

tag="${1:?usage: scripts/set-version.sh vMAJOR.MINOR.PATCH}"
version="${tag#v}"
if ! printf '%s\n' "$version" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?$'; then
    echo "error: tag '$tag' is not a version like v1.2.3" >&2
    exit 1
fi

file="$(cd "$(dirname "$0")/.." && pwd)/Sources/MeanwhileCore/Meanwhile.swift"
sed -i '' -E "s/(public static let version = )\"[^\"]*\"/\1\"$version\"/" "$file"
grep -q "public static let version = \"$version\"" "$file" || { echo "error: couldn't set the version in $file" >&2; exit 1; }
echo "Meanwhile.version = $version"
