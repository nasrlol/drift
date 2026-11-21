#!/bin/sh
set -e
cd "$(dirname "$0")/../assets"

SRC=raw/belgium.osm.pbf
OUT=geojson
# GDAL from the micromamba env where there is one (laptop), else the system ogr2ogr (apt).
if command -v micromamba >/dev/null 2>&1; then GIS="micromamba run -n gis"; else GIS=; fi
OGR="$GIS ogr2ogr -f GeoJSON -lco COORDINATE_PRECISION=5"
mkdir -p "$OUT"; rm -f $OUT/*.geojson

$OGR $OUT/border.geojson    -select name $SRC multipolygons -where "boundary='administrative' AND admin_level='2' AND name LIKE 'Belgi% / Belgique / Belgien'" -simplify 0.0005
$OGR $OUT/rivers.geojson    -select name $SRC lines -where "waterway='river'" -simplify 0.0005
# ref (motorway number, e.g. "E40;A10") is not a column of the OSM driver, it sits in the other_tags hstore.
$OGR $OUT/roads.geojson     $SRC -dialect SQLite -sql "SELECT name, highway, hstore_get_value(other_tags, 'ref') AS ref, geometry FROM lines WHERE highway IN ('motorway','motorway_link','trunk','trunk_link','primary','primary_link','secondary','secondary_link','tertiary','tertiary_link')" -simplify 0.0005
gzip -9 -n -f $OUT/roads.geojson
$OGR $OUT/cities.geojson    -select name $SRC points -where "place='city'"
# Land use for the map colours. OGR_GEOM_AREA is in square degrees before simplifying: 0.00005 is ~0.4 km2,
# the bake drops what is below AREA_MIN_KM2 after simplifying. 180 MB without the area filter.
$OGR $OUT/areas.geojson     -select landuse,natural,leisure $SRC multipolygons -where "(landuse IN ('residential','commercial','industrial','retail','forest','farmland','farmyard','orchard','vineyard') OR \"natural\" IN ('wood','wetland','beach','sand','water') OR leisure='park') AND OGR_GEOM_AREA > 0.00005" -simplify 0.001
gzip -9 -n -f $OUT/areas.geojson

ls -lh $OUT
