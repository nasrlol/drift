#!/bin/sh
set -e
cd "$(dirname "$0")/../assets"

SRC=raw/belgium.osm.pbf
OUT=geojson
OGR="micromamba run -n gis ogr2ogr -f GeoJSON -lco COORDINATE_PRECISION=5"
mkdir -p "$OUT"; rm -f $OUT/*.geojson

$OGR $OUT/border.geojson    -select name $SRC multipolygons -where "boundary='administrative' AND admin_level='2' AND name LIKE 'Belgi% / Belgique / Belgien'" -simplify 0.0005
$OGR $OUT/rivers.geojson    -select name $SRC lines -where "waterway='river'" -simplify 0.0005
$OGR $OUT/roads.geojson     -select name,highway $SRC lines -where "highway IN ('motorway','motorway_link','trunk','trunk_link','primary','primary_link','secondary','secondary_link','tertiary','tertiary_link')" -simplify 0.0005
gzip -9 -n -f $OUT/roads.geojson
$OGR $OUT/cities.geojson    -select name $SRC points -where "place='city'"

ls -lh $OUT
