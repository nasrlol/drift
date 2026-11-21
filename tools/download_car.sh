#!/bin/sh
# The car model for tools/bake_car: Car Concept from the Khronos glTF Sample Assets, CC BY 4.0, Eric Chadwick /
# Darmstadt Graphics Group, made from a public domain (CC0) model by Unity Fan. See assets/car-LICENSE.txt.
# Into assets/raw/car/ (not in git), checked against its sha256.
set -e
cd "$(dirname "$0")/.."
OUT=assets/raw/car/CarConcept.glb
URL=https://raw.githubusercontent.com/KhronosGroup/glTF-Sample-Assets/main/Models/CarConcept/glTF-Binary/CarConcept.glb
SHA=c272098089d78c5cd9fd9f24ff50ee8acf8d932c55f2d55fc10adb6c8998966b
mkdir -p assets/raw/car
[ -f "$OUT" ] || curl -sS --retry 3 --max-time 120 -o "$OUT" "$URL"
echo "$SHA  $OUT" | sha256sum -c -
