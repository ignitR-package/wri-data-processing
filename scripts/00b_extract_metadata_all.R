# =============================================================================
# 00b_extract_metadata_all.R - Extract metadata for ALL WRI GeoTIFFs
#
# Purpose:
#   Extract header metadata for all WRI GeoTIFFs under data/ and verify the
#   fixed project assumptions (EPSG:5070, 90x90m resolution, consistent extent).
#   Classifies each file by data_type, domain, and dimension for downstream
#   STAC item properties.
#
# Outputs:
#   metadata/all_layers_consistent.csv   - valid files passing assumptions (always)
#   metadata/all_layers_raw.csv          - all results (only if issues exist)
#   metadata/all_layers_inconsistent.csv - files failing assumptions (only if issues exist)
#
# Notes:
#   - No raster modification occurs here.
#   - Simple resume support: if raw CSV exists, previously processed files are skipped.
#   - CRS/extent/resolution are assumed consistent across dataset but validated
#     per-file as a QC check.
# =============================================================================

library(terra)
library(readr)
library(dplyr)
library(fs)

source("scripts/R/utils.R")

# --- Config -------------------------------------------------------------------

raw_data_path <- "data"
dir_create("metadata")

out_raw          <- "metadata/all_layers_raw.csv"
out_consistent   <- "metadata/all_layers_consistent.csv"
out_inconsistent <- "metadata/all_layers_inconsistent.csv"

# Expected values (project assumptions)
# These are documented in the README and verified here as a sanity check.
expected <- list(
  epsg  = 5070,
  res_x = 90,
  res_y = 90,
  xmin  = -5216639.67,
  xmax  = -504689.6695,
  ymin  = 991231.6885,
  ymax  = 6199081.688
)

# Numeric tolerance for floating point comparisons
tol <- 1e-6

# --- Resume support -----------------------------------------------------------
# If we've already processed some files, skip them on re-run.
# This allows recovery from interruptions without starting over.

processed_files <- character(0)

if (file_exists(out_raw)) {
  old <- read_csv(out_raw, show_col_types = FALSE)
  if ("filepath" %in% names(old)) processed_files <- old$filepath
  cat("Previously processed:", length(processed_files), "\n")
}

# --- List files ---------------------------------------------------------------
# Find all .tif files and filter out "exclude" types (archive, final_checks, etc.)

all_tifs <- dir_ls(raw_data_path, recurse = TRUE, glob = "*.tif")

# classify_data_type returns "exclude" for files we don't want to process
files <- all_tifs[vapply(all_tifs, classify_data_type, character(1)) != "exclude"]

# Remove already-processed files (resume support)
files <- files[!files %in% processed_files]

cat("Files to process:", length(files), "\n")

# --- Process ------------------------------------------------------------------
# Extract metadata for each file and validate against project assumptions.
# Results are buffered and written in batches to avoid memory issues.

buffer <- list()
batch_n <- 10

for (i in seq_along(files)) {
  fp <- files[i]
  cat(sprintf("[%d/%d] %s\n", i, length(files), basename(fp)))
  
  # Extract header metadata (no value sampling, just dimensions/CRS/extent)
  info <- get_raster_header(fp)
  
  # --- Classification fields ---
  # These are used downstream in STAC item properties to enable filtering
  # by data type (indicator/aggregate/final_score), domain (livelihoods, etc.),
  # and dimension (resistance/recovery/status/domain_score).
  info$data_type <- classify_data_type(fp)
  info$wri_domain <- extract_domain(fp)
  info$wri_dimension <- classify_dimension(info$data_type, basename(fp))
  info$cog_filename <- make_cog_filename(fp)
  
  # Initialize assumption check fields
  info$passes_assumptions <- NA
  info$assumption_error <- NA_character_
  
  # --- Validate assumptions (only for successfully read files) ---
  if (isTRUE(info$success)) {
    err <- NULL
    
    # Check CRS
    if (is.na(info$crs_epsg)) {
      err <- "EPSG is NA"
    } else if (info$crs_epsg != expected$epsg) {
      err <- paste0("EPSG mismatch (", info$crs_epsg, ")")
    }
    
    # Check resolution
    if (is.null(err)) {
      if (!near(info$resolution_x, expected$res_x, tol) || 
          !near(info$resolution_y, expected$res_y, tol)) {
        err <- paste0("Resolution mismatch (", info$resolution_x, "x", info$resolution_y, ")")
      }
    }
    
    # Check extent
    if (is.null(err)) {
      if (!near(info$extent_xmin, expected$xmin, tol) ||
          !near(info$extent_xmax, expected$xmax, tol) ||
          !near(info$extent_ymin, expected$ymin, tol) ||
          !near(info$extent_ymax, expected$ymax, tol)) {
        err <- "Extent mismatch"
      }
    }
    
    # Record result
    if (is.null(err)) {
      info$passes_assumptions <- TRUE
    } else {
      info$passes_assumptions <- FALSE
      info$assumption_error <- err
    }
  }
  
  buffer[[length(buffer) + 1]] <- info
  
  # Write in batches to avoid holding everything in memory
  if (length(buffer) >= batch_n) {
    append_rows_csv(buffer, out_raw)
    buffer <- list()
  }
}

# Write any remaining rows
if (length(buffer) > 0) append_rows_csv(buffer, out_raw)

cat("Saved:", out_raw, "\n")

# --- Split and save -----------------------------------------------------------
# Always produce the consistent CSV. Only keep raw/inconsistent if there are
# problems (failed reads or files that don't pass assumptions).

all_meta <- read_csv(out_raw, show_col_types = FALSE)

successful   <- all_meta %>% filter(success == TRUE)
consistent   <- successful %>% filter(passes_assumptions == TRUE)
inconsistent <- successful %>% filter(passes_assumptions == FALSE)

write_csv(consistent, out_consistent)

# Keep diagnostic files only if there are issues to investigate
if (nrow(inconsistent) > 0 || nrow(all_meta) > nrow(successful)) {
  write_csv(inconsistent, out_inconsistent)
  cat("Saved:", out_raw, "\n")
  cat("Saved:", out_inconsistent, "\n")
} else {
  # Everything passed - clean up intermediate file
  file_delete(out_raw)
}

cat("Saved:", out_consistent, "\n")

# --- Summary ------------------------------------------------------------------

cat("\nSummary\n")
cat("  Total:        ", nrow(all_meta), "\n")
cat("  Consistent:   ", nrow(consistent), "\n")
cat("  Inconsistent: ", nrow(inconsistent), "\n")
cat("  Failed reads: ", nrow(all_meta) - nrow(successful), "\n")