# =============================================================================
# 01a: Convert ONE GeoTIFF to COG
# =============================================================================

# Input GeoTIFF
in_tif <- "data/livelihoods/livelihoods_domain_score.tif"

# Output directory
out_dir <- "scratch_output/"
dir.create(out_dir, showWarnings = FALSE)

# Output COG path (same filename)
out_cog <- file.path(out_dir, basename(in_tif))

# Rerun-safe: skip if output exists
if (file.exists(out_cog)) {
  cat("COG exists, skipping:", out_cog, "\n")
  quit(status = 0)
}

# Build gdal_translate command
cmd <- paste(
  "gdal_translate",
  "-of COG",
  "-co COMPRESS=DEFLATE",
  "-co PREDICTOR=YES",
  "-co BLOCKSIZE=512",
  "-co RESAMPLING=AVERAGE", # For continuous values
  "-co OVERVIEWS=IGNORE_EXISTING",
  "-co NUM_THREADS=50",
  shQuote(in_tif),
  shQuote(out_cog)
)

# Run command
system(cmd)

cat("Wrote:", out_cog, "\n")
