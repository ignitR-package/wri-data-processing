# =============================================================================
# 01a_make_cog_one.R - Convert ONE GeoTIFF to COG (prototype)
# =============================================================================

library(terra)
library(gdalUtilities)

# --- Config -------------------------------------------------------------------

# Define test file metadata path
meta_csv <- "scratch_output/livelihoods_domain_score_metadata.csv"

# Define test file path and output directory
in_tif  <- "data/livelihoods/livelihoods_domain_score.tif"
out_dir <- "scratch_output/cogs"

# Create directory if it does not exist
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
out_cog <- file.path(out_dir, basename(in_tif))

# --- Config for gdal_translate --------------------------------------------

gdal_translate <- Sys.which("gdal_translate")
if (gdal_translate == "") stop("gdal_translate not found on PATH")

cog_co <- c(
  "COMPRESS=DEFLATE",
  "BLOCKSIZE=512",
  "NUM_THREADS=50",
  "RESAMPLING=AVERAGE"
)

co_args <- as.vector(rbind("-co", cog_co))

# --- Run ----------------------------------------------------------------------

# Check that metadata exists
if (!file.exists(meta_csv)) stop("Missing metadata CSV: ", meta_csv)

# Load metadata
meta <- readr::read_csv(meta_csv)

# Extract the metadata 
in_tif  <- meta$filepath[1]

# Define cog output
out_cog <- file.path(out_dir, meta$cog_filename[1])

# Convert to COG
gdal_translate(
  src_dataset = in_tif,
  dst_dataset = out_cog,
  of = "COG",
  co = cog_co
)

out_size <- round(file.info(out_cog)$size / 1024^2, 2)
cat("  Wrote:", out_cog, "(", out_size, "MB)\n")