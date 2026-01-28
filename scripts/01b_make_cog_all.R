# =============================================================================
# Script: scripts/01b_convert_cogs_all_consistent.R
#
# Purpose:
#   Convert ALL "consistent" GeoTIFFs (from the metadata CSV) into COGs.
#
# Inputs:
#   - config/all_layers_consistent.csv   (produced by 00b)
#
# Outputs:
#   - cogs/<same filename>.tif
#
# Notes:
#   - Uses the metadata CSV to choose which files to convert.
#   - Does NOT re-extract metadata.
#   - Rerun-safe: skips files whose COG already exists.
#   - Does NOT call quit() (safe in interactive sessions).
# =============================================================================

library(terra)
library(readr)

# Make terra non-interactive about overwriting (prevents prompts)
terraOptions(overwrite = TRUE)

# --- Config ---------------------------------------------------------------

meta_csv <- "config/all_layers_consistent.csv"
out_dir  <- "cogs"

dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

# --- Run ------------------------------------------------------------------

if (!file.exists(meta_csv)) stop("Missing metadata CSV: ", meta_csv)

meta <- readr::read_csv(meta_csv, show_col_types = FALSE)

if (!("filepath" %in% names(meta))) {
  stop("Metadata file is missing a 'filepath' column: ", meta_csv)
}

if (nrow(meta) == 0) {
  cat("No rows in metadata file. Nothing to convert.\n")
} else {
  
  n_total   <- nrow(meta)
  n_written <- 0
  n_skipped <- 0
  n_missing <- 0
  n_failed  <- 0
  
  for (i in seq_len(n_total)) {
    in_tif  <- meta$filepath[i]
    out_cog <- file.path(out_dir, basename(in_tif))
    
    cat(sprintf("[%d/%d] %s\n", i, n_total, basename(in_tif)))
    
    # Skip if input missing
    if (!file.exists(in_tif)) {
      cat("  Missing input, skipping:", in_tif, "\n")
      n_missing <- n_missing + 1
      next
    }
    
    # Skip if already converted
    if (file.exists(out_cog)) {
      cat("  COG exists, skipping:", out_cog, "\n")
      n_skipped <- n_skipped + 1
      next
    }
    
    # Convert (catch errors so the loop continues)
    ok <- TRUE
    err_msg <- NA_character_
    
    tryCatch({
      r <- terra::rast(in_tif)
      
      # overwrite=TRUE here prevents GDAL/terra prompts.
      # It is safe because we already checked file.exists(out_cog) above.
      terra::writeRaster(
        r,
        out_cog,
        filetype  = "COG",
        overwrite = TRUE,
        gdal=c("NUM_THREADS=50")
      )
    }, error = function(e) {
      ok <<- FALSE
      err_msg <<- as.character(e)
    })
    
    if (ok) {
      cat("  Wrote:", out_cog, "\n")
      n_written <- n_written + 1
    } else {
      cat("  FAILED:", err_msg, "\n")
      n_failed <- n_failed + 1
    }
  }
  
  cat("\nDone.\n")
  cat("  Total in metadata:", n_total, "\n")
  cat("  Written:", n_written, "\n")
  cat("  Skipped (exists):", n_skipped, "\n")
  cat("  Missing inputs:", n_missing, "\n")
  cat("  Failed conversions:", n_failed, "\n")
}
