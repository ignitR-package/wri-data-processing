# 01a: Convert ONE GeoTIFF to COG

# Input GeoTIFF
IN_TIF="data/livelihoods/livelihoods_domain_score.tif"

# Output directory
OUT_DIR="cogs"
mkdir -p "${OUT_DIR}"

# Output COG path (same basename as input)
OUT_COG="${OUT_DIR}/$(basename "${IN_TIF}")"

# Rerun safe
if [ -f "${OUT_COG}" ]; then
echo "COG exists, skipping: ${OUT_COG}"
exit 0
fi

# Convert to COG
# Notes:
# - Float32 continuous score, so overview resampling = AVERAGE
# - Blocksize 512 makes it tiled (your source is striped 52355x1)
# - NUM_THREADS capped at 50 for your cluster policy
gdal_translate \
-of COG \
-co COMPRESS=DEFLATE \
-co PREDICTOR=YES \
-co BLOCKSIZE=512 \
-co RESAMPLING=AVERAGE \
-co OVERVIEWS=IGNORE_EXISTING \
-co NUM_THREADS=50 \
"${IN_TIF}" \
"${OUT_COG}"

echo "Wrote: ${OUT_COG}"