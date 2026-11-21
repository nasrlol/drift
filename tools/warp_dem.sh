#!/bin/sh
# Copernicus DEM tiles (tools/download_dem.sh) -> assets/geojson/heights.i16.gz: one i16 height in m per 250 m
# cell over 0..286 x 0..237 km of map space, 1144 x 948 cells, row-major, y down, little endian.
# tools/bake_map turns it into the heightmap block of belgium.bin.
set -e
cd "$(dirname "$0")/../assets"

if command -v micromamba >/dev/null 2>&1; then GIS="micromamba run -n gis"; else GIS=; fi

# The bake projects with x = (lon - 2.38) * 111.32 km * cos(50.5), y = (51.56 - lat) * 111.32 km.
# eqc gives the same with lat_ts = 50.5 and R = 111320 m * 180 / pi; with lat_0 = 51.56 the map top is
# northing 0 and y down is minus northing. R = 6378137 would put the far corner 1.3 m off.
SRS="+proj=eqc +lat_ts=50.5 +lat_0=51.56 +lon_0=2.38 +x_0=0 +y_0=0 +R=6378166.175 +units=m +no_defs"
TMP=raw/dem/warp
mkdir -p $TMP
rm -f $TMP/*

$GIS gdalbuildvrt $TMP/dem.vrt raw/dem/*.tif
# average: 250 m cells from ~90 m samples, the height of the whole cell rather than of one sample in it.
# Pixels are areas, so cell (i, j) is centred on ((i + 0.5) * 0.25, (j + 0.5) * 0.25) km.
$GIS gdalwarp -q -t_srs "$SRS" -te 0 -237000 286000 0 -tr 250 250 -r average -ot Int16 -dstnodata none \
	-of EHdr $TMP/dem.vrt $TMP/heights.bil
grep -q 'BYTEORDER *I' $TMP/heights.hdr
grep -q 'NROWS *948' $TMP/heights.hdr
grep -q 'NCOLS *1144' $TMP/heights.hdr
gzip -9 -n -c $TMP/heights.bil > geojson/heights.i16.gz
ls -l $TMP/heights.bil geojson/heights.i16.gz
