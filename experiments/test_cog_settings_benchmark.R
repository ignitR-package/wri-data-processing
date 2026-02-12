# =============================================================================
# 01a_make_cog_one.R
#
# Purpose:
#   Convert ONE input GeoTIFF into MANY Cloud Optimized GeoTIFFs (COGs),
#   one per combination of lossless COG creation settings.
#
# What it does:
#   1. Reads a metadata CSV to get the input GeoTIFF path.
#   2. Builds a grid of COG settings.
#   3. For each settings combo, writes one output COG, but SKIPS it if the file
#      already exists (safe for reruns).
#   4. Writes a CSV log that records each output file, settings, and whether it
#      was created or skipped.
# =============================================================================

library(gdalUtilities)
library(tidyr)
library(readr)

# --- Paths --------------------------------------------------------------------

meta_csv <- "scratch_output/livelihoods_domain_score_metadata.csv"
out_dir  <- "scratch_output/cogs"
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

# --- Load input GeoTIFF path --------------------------------------------------

if (!file.exists(meta_csv)) stop("Missing metadata CSV: ", meta_csv)
meta   <- read_csv(meta_csv, show_col_types = FALSE)
in_tif <- meta$filepath[1]
if (!file.exists(in_tif)) stop("Missing input tif: ", in_tif)

base_id <- tools::file_path_sans_ext(basename(in_tif))

# --- Settings grid ------------------------------------------------------------

grid <- expand_grid(
  COMPRESS   = c("DEFLATE", "ZSTD", "LZW"),
  PREDICTOR  = c(2, 3),
  BLOCKSIZE  = c(256, 512),
  BIGTIFF    = c("IF_SAFER", "YES"),
  RESAMPLING = c("NEAREST", "AVERAGE")
)

# --- Run: one COG per settings row -------------------------------------------

log <- vector("list", nrow(grid))

for (i in seq_len(nrow(grid))) {
  row <- grid[i, ]
  
  co <- c(
    paste0("COMPRESS=",   row$COMPRESS),
    paste0("PREDICTOR=",  row$PREDICTOR),
    paste0("BLOCKSIZE=",  row$BLOCKSIZE),
    paste0("BIGTIFF=",    row$BIGTIFF),
    paste0("RESAMPLING=", row$RESAMPLING)
  )
  
  tag <- paste(
    paste0("cmp-", tolower(row$COMPRESS)),
    paste0("pred-", row$PREDICTOR),
    paste0("blk-", row$BLOCKSIZE),
    paste0("bigtiff-", tolower(row$BIGTIFF)),
    paste0("rs-", tolower(row$RESAMPLING)),
    sep = "_"
  )
  
  out_cog <- file.path(out_dir, paste0(base_id, "__", tag, ".tif"))
  
  if (file.exists(out_cog)) {
    cat("Skip (exists):", out_cog, "\n")
    status <- "skipped_exists"
  } else {
    gdal_translate(
      src_dataset = in_tif,
      dst_dataset = out_cog,
      of = "COG",
      co = co
    )
    cat("Wrote:", out_cog, "\n")
    status <- "created"
  }
  
  log[[i]] <- data.frame(
    out_cog = out_cog,
    status = status,
    COMPRESS = row$COMPRESS,
    PREDICTOR = row$PREDICTOR,
    BLOCKSIZE = row$BLOCKSIZE,
    BIGTIFF = row$BIGTIFF,
    RESAMPLING = row$RESAMPLING,
    stringsAsFactors = FALSE
  )
}

log_df <- do.call(rbind, log)
write_csv(log_df, file.path(out_dir, paste0(base_id, "__cog_settings_log.csv")))

cat("Done. Log CSV written in:", out_dir, "\n")