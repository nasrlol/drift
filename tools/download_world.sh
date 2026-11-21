#!/bin/bash
set -euo pipefail

DIR="assets/geojson"
BASE="https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson"
mkdir -p "$DIR"

for f in \
	ne_50m_land.geojson \
	ne_50m_admin_0_boundary_lines_land.geojson \
	ne_50m_populated_places_simple.geojson
do
	out="$DIR/$f"
	case "$f" in
		ne_50m_admin_0_boundary_lines_land.geojson) out="$DIR/ne_50m_borders.geojson" ;;
		ne_50m_populated_places_simple.geojson) out="$DIR/ne_50m_cities.geojson" ;;
	esac
	echo "Downloading $f -> $out"
	curl -fsSL --retry 3 --max-time 60 "$BASE/$f" -o "$out.tmp"
	mv "$out.tmp" "$out"
done
