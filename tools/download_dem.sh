#!/bin/sh
# Copernicus DEM GLO-90 tiles over the map (lat 49.43..51.56, lon 2.38..6.42) into assets/raw/dem/.
# Tiles are 1 x 1 degree, named after their south-west corner. Sea-only tiles do not exist (404), skipped.
# Already downloaded tiles are kept. Every file is checked against tools/dem_tiles.sha256.
set -e
cd "$(dirname "$0")/.."

URL=https://copernicus-dem-90m.s3.amazonaws.com
OUT=assets/raw/dem
mkdir -p "$OUT"

for lat in 49 50 51; do
	for lon in 002 003 004 005 006; do
		name="Copernicus_DSM_COG_30_N${lat}_00_E${lon}_00_DEM"
		file="$OUT/$name.tif"
		[ -f "$file" ] && continue
		code=$(curl -sS --retry 3 --max-time 120 -o "$file.tmp" -w '%{http_code}' "$URL/$name/$name.tif")
		case "$code" in
			200) mv "$file.tmp" "$file" && echo "downloaded $name" ;;
			404) rm -f "$file.tmp" && echo "no tile $name (sea)" ;;
			*) rm -f "$file.tmp" && echo "download_dem: $name: HTTP $code" && exit 1 ;;
		esac
	done
done

cd "$OUT"
sha256sum -c --quiet ../../../tools/dem_tiles.sha256
echo "download_dem: $(ls *.tif | wc -l) tiles in $OUT, checksums ok"
