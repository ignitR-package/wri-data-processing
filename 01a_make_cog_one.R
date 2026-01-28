# =============================================================================
# Script: scratch/01a_convert_cog_one.R
#
# Purpose:
#   Convert ONE GeoTIFF to a Cloud Optimized GeoTIFF (COG).
#   Prototype for the scaled script (01b).
#
# Notes:
#   - This does not modify the input file.
#   - Rerun-safe: skips if output exists.
# =============================================================================

library(terra)

# --- Config ---------------------------------------------------------------

in_tif  <- "data/livelihoods/livelihoods_domain_score.tif"
out_dir <- "scratch_output/cogs"

dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

out_cog <- file.path(out_dir, basename(in_tif))

# --- Run ------------------------------------------------------------------

if (!file.exists(in_tif)) stop("Input file not found: ", in_tif)

if (file.exists(out_cog)) {
  cat("COG exists, skipping:", out_cog, "\n")
} else {
  r <- terra::rast(in_tif)
  terra::writeRaster(
    r,
    out_cog,
    filetype = "COG",
    overwrite = TRUE
  )
  cat("Wrote:", out_cog, "\n")
}
