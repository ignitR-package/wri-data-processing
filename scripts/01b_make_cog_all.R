# =============================================================================
# 01b_make_cog_all.R - Convert ALL consistent GeoTIFFs to COGs
#
# Purpose:
#   Convert all files that passed metadata validation into Cloud Optimized
#   GeoTIFFs (COGs). COGs enable efficient cloud-based access by organizing
#   data with internal tiling and overviews.
#
# Input:
#   config/all_layers_consistent.csv (produced by 00b)
#
# Output:
#   cogs/<filename>.tif
#
# Notes:
#   - Uses the metadata CSV to determine which files to convert.
#   - Does NOT re-extract or validate metadata.
#   - Rerun-safe: skips files whose COG already exists.
#   - Errors are caught and logged so the loop continues.
# =============================================================================

library(terra)
library(readr)

# Prevent terra from prompting about overwrites
terraOptions(overwrite = TRUE)

# --- Config -------------------------------------------------------------------

meta_csv <- "config/all_layers_consistent.csv"
out_dir  <- "cogs"

dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

# --- Run ----------------------------------------------------------------------

if (!file.exists(meta_csv)) stop("Missing metadata CSV: ", meta_csv)

meta <- readr::read_csv(meta_csv, show_col_types = FALSE)

if (!"filepath" %in% names(meta)) {
  stop("Metadata CSV missing 'filepath' column")
}

if (nrow(meta) == 0) {
  cat("No files to convert.\n")
  quit(save = "no")
}

n_total <- nrow(meta)
counts <- c(written = 0, skipped = 0, missing = 0, failed = 0)

cat("Converting", n_total, "files to COG format\n")
cat("Output directory:", out_dir, "\n\n")

for (i in seq_len(n_total)) {
  in_tif  <- meta$filepath[i]
  out_cog <- file.path(out_dir, basename(in_tif))
  
  cat(sprintf("[%d/%d] %s\n", i, n_total, basename(in_tif)))
  
  # Skip if input file is missing (shouldn't happen, but check anyway)
  if (!file.exists(in_tif)) {
    cat("  WARNING: Input file missing, skipping\n")
    counts["missing"] <- counts["missing"] + 1
    next
  }
  
  # Skip if COG already exists (allows resume after interruption)
  if (file.exists(out_cog)) {
    cat("  Already exists, skipping\n")
    counts["skipped"] <- counts["skipped"] + 1
    next
  }
  
  # Attempt conversion with error handling
  ok <- tryCatch({
    r <- terra::rast(in_tif)
    terra::writeRaster(r, out_cog, filetype = "COG", overwrite = TRUE)
    TRUE
  }, error = function(e) {
    cat("  ERROR:", conditionMessage(e), "\n")
    FALSE
  })
  
  if (ok) {
    out_size <- round(file.info(out_cog)$size / 1024^2, 2)
    cat("  Wrote:", out_cog, "(", out_size, "MB)\n")
    counts["written"] <- counts["written"] + 1
  } else {
    counts["failed"] <- counts["failed"] + 1
  }
}

# --- Summary ------------------------------------------------------------------

cat("\n")
cat("=== Conversion Summary ===\n")
cat("  Total in metadata:", n_total, "\n")
cat("  Written:          ", counts["written"], "\n")
cat("  Skipped (exists): ", counts["skipped"], "\n")
cat("  Missing inputs:   ", counts["missing"], "\n")
cat("  Failed:           ", counts["failed"], "\n")