#!/bin/sh
# OSM buildings around each city for tools/bake_buildings: assets/raw/belgium.osm.pbf -> one geojson per city
# in assets/raw/buildings/ (not in git). Each ogr2ogr pass reads the whole extract (~2.5 min), 4 at a time.
set -e
cd "$(dirname "$0")/.."
if command -v micromamba >/dev/null 2>&1; then GIS="micromamba run -n gis"; else GIS=; fi
OUT=assets/raw/buildings
mkdir -p "$OUT"
odin run tools/bake_buildings -- boxes | while read -r i x0 y0 x1 y1; do
	echo "$GIS ogr2ogr -f GeoJSON -lco COORDINATE_PRECISION=6 $OUT/$i.geojson assets/raw/belgium.osm.pbf -dialect SQLite -sql \"SELECT hstore_get_value(other_tags,'building:levels') AS levels, hstore_get_value(other_tags,'height') AS height, geometry FROM multipolygons WHERE building IS NOT NULL\" -spat $x0 $y0 $x1 $y1"
done | xargs -P 4 -I {} sh -c "{}"
ls -l "$OUT"
