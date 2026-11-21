#!/bin/sh
set -e
cd "$(dirname "$0")/../assets"

SRC=raw/belgium.osm.pbf
OUT=geojson
OGR="micromamba run -n gis ogr2ogr -f GeoJSON -select name -lco COORDINATE_PRECISION=5"
mkdir -p "$OUT"; rm -f $OUT/*.geojson

$OGR $OUT/border.geojson    $SRC multipolygons -where "boundary='administrative' AND admin_level='2' AND name LIKE 'Belgi% / Belgique / Belgien'" -simplify 0.0005
$OGR $OUT/rivers.geojson    $SRC lines -where "waterway='river'" -simplify 0.0005
$OGR $OUT/motorways.geojson $SRC lines -where "highway='motorway'" -simplify 0.0005
$OGR $OUT/cities.geojson    $SRC points -where "place='city'"

ls -lh $OUT
