#!/bin/sh
# Builds a universal (arm64 + x86_64) release and packages it for GitHub Releases:
#   dist/meanwhile-<version>-macos.tar.gz   meanwhile-<version>-macos/{meanwhile, meanwhile-hook, *.bundle}
#   dist/SHA256SUMS
# The version is Meanwhile.version (run scripts/set-version.sh first for a release).
# The layout matches what `meanwhile setup` copies: the executables and the resource bundles beside them.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
version="$(sed -n -E 's/.*public static let version = "([^"]+)".*/\1/p' Sources/MeanwhileCore/Meanwhile.swift)"
[ -n "$version" ] || { echo "error: couldn't read Meanwhile.version" >&2; exit 1; }

swift build -c release --arch arm64 --arch x86_64
products=".build/apple/Products/Release"

name="meanwhile-$version-macos"
dist="$root/dist"
stage="$dist/$name"
rm -rf "$dist"
mkdir -p "$stage"

for tool in meanwhile meanwhile-hook; do
    cp "$products/$tool" "$stage/$tool"
    codesign --force -s - "$stage/$tool"
done
found=0
for bundle in "$products"/*.bundle; do
    [ -e "$bundle" ] || continue
    case "$(basename "$bundle")" in *Tests*) continue ;; esac
    cp -R "$bundle" "$stage/"
    found=1
done
[ "$found" = 1 ] || { echo "error: no resource bundles in $products" >&2; exit 1; }

"$stage/meanwhile" --version
for tool in meanwhile meanwhile-hook; do echo "$tool: $(lipo -archs "$stage/$tool")"; done

COPYFILE_DISABLE=1 tar -czf "$dist/$name.tar.gz" -C "$dist" "$name"
rm -rf "$stage"
(cd "$dist" && shasum -a 256 "$name.tar.gz" > SHA256SUMS)
cat "$dist/SHA256SUMS"
echo "Packaged $dist/$name.tar.gz"
