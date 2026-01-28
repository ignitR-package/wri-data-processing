# =============================================================================
# Script: scripts/00b_extract_metadata_all.R
#
# Purpose:
#   Extract metadata for ALL WRI GeoTIFFs under data/ and verify the fixed
#   project assumptions:
#     - EPSG:5070
#     - resolution 90 x 90 (meters)
#     - extent:
#         xmin = -5216639.67
#         xmax =  -504689.6695
#         ymin =   991231.6885
#         ymax =  6199081.688
#
# Outputs (3 files):
#   - config/all_layers_raw.csv           (all results, including failures)
#   - config/all_layers_consistent.csv    (successful + passes assumptions)
#   - config/all_layers_inconsistent.csv  (successful + fails assumptions)
#
# Notes:
#   - No raster modification.
#   - Simple "resume": if all_layers_raw.csv exists, we skip files already in it.
# =============================================================================

library(terra)
library(readr)
library(dplyr)
library(fs)

source("scripts/R/utils.R")

# --- Config ---------------------------------------------------------------

raw_data_path <- "data"

dir_create("config")

out_raw         <- "config/all_layers_raw.csv"
out_consistent  <- "config/all_layers_consistent.csv"
out_inconsistent<- "config/all_layers_inconsistent.csv"

# Expected constants (assumptions)
expected_epsg <- 5070
expected_res_x <- 90
expected_res_y <- 90

expected_xmin <- -5216639.67
expected_xmax <-  -504689.6695
expected_ymin <-   991231.6885
expected_ymax <-  6199081.688

# Sampling
sample_size <- 200000
set.seed(1)

# Numeric tolerance for comparisons (avoid floating point false mismatches)
tol <- 1e-6

# --- Resume support -------------------------------------------------------

processed_files <- character(0)

if (file_exists(out_raw)) {
  old <- read_csv(out_raw, show_col_types = FALSE)
  if ("filepath" %in% names(old)) processed_files <- old$filepath
  cat("Found existing raw metadata. Previously processed:", length(processed_files), "\n")
}

# --- List all tif files ---------------------------------------------------

all_tifs <- dir_ls(raw_data_path, recurse = TRUE, glob = "*.tif")

# Keep only files we want to track (based on your WRI rules)
files <- all_tifs[vapply(all_tifs, classify_data_type, character(1)) != "exclude"]

# Skip previously processed
if (length(processed_files) > 0) {
  files <- files[!files %in% processed_files]
}

cat("Files to process:", length(files), "\n")

# --- Helper: compare numbers with tolerance -------------------------------

near_num <- function(a, b, tol) {
  isTRUE(all.equal(as.numeric(a), as.numeric(b), tolerance = tol))
}

# --- Process all files ----------------------------------------------------

buffer <- list()
batch_n <- 10

for (i in seq_along(files)) {
  fp <- files[i]
  cat(sprintf("[%d/%d] %s\n", i, length(files), basename(fp)))
  
  # Extract metadata + sample stats (from utils.R)
  info <- get_raster_info(fp, sample_size = sample_size)
  
  # Default flags
  info$passes_assumptions <- NA
  info$assumption_error   <- NA_character_
  
  # If raster load failed, keep it as a failure row
  if (!isTRUE(info$success)) {
    buffer[[length(buffer) + 1]] <- info
  } else {
    # --- Verify assumptions (only if success == TRUE) ---
    
    # Check EPSG (integer)
    epsg <- info$crs
    if (is.na(epsg)) {
      info$passes_assumptions <- FALSE
      info$assumption_error <- "EPSG is NA (expected 5070)"
    } else if (as.integer(epsg) != expected_epsg) {
      info$passes_assumptions <- FALSE
      info$assumption_error <- paste0("EPSG mismatch (found ", epsg, ", expected 5070)")
    }
    
    # Check resolution (numeric with tolerance)
    if (is.na(info$passes_assumptions)) {
      rx <- info$resolution_x
      ry <- info$resolution_y
      if (!near_num(rx, expected_res_x, tol) || !near_num(ry, expected_res_y, tol)) {
        info$passes_assumptions <- FALSE
        info$assumption_error <- paste0(
          "Resolution mismatch (found ", rx, "x", ry, ", expected 90x90)"
        )
      }
    }
    
    # Check extent (numeric with tolerance)
    if (is.na(info$passes_assumptions)) {
      if (!near_num(info$extent_xmin, expected_xmin, tol) ||
          !near_num(info$extent_xmax, expected_xmax, tol) ||
          !near_num(info$extent_ymin, expected_ymin, tol) ||
          !near_num(info$extent_ymax, expected_ymax, tol)) {
        
        info$passes_assumptions <- FALSE
        info$assumption_error <- "Extent mismatch (does not match expected xmin/xmax/ymin/ymax)"
      }
    }
    
    # If nothing failed, it passes
    if (is.na(info$passes_assumptions)) {
      info$passes_assumptions <- TRUE
      info$assumption_error <- NA_character_
    }
    
    buffer[[length(buffer) + 1]] <- info
  }
  
  # Append in small batches
  if (length(buffer) >= batch_n) {
    append_rows_csv(buffer, out_raw)
    buffer <- list()
  }
}

# Write any remaining rows
if (length(buffer) > 0) {
  append_rows_csv(buffer, out_raw)
}

cat("Saved/updated:", out_raw, "\n")

# --- Split into consistent/inconsistent and write the other 2 files --------

all_meta <- read_csv(out_raw, show_col_types = FALSE)

# Ensure assumption columns exist (for resume safety)
if (!"passes_assumptions" %in% names(all_meta)) {
  all_meta$passes_assumptions <- NA
}
if (!"assumption_error" %in% names(all_meta)) {
  all_meta$assumption_error <- NA_character_
}


successful <- all_meta %>% filter(success)
consistent <- successful %>% filter(passes_assumptions)
inconsistent <- successful %>% filter(!passes_assumptions)

write_csv(consistent, out_consistent)
write_csv(inconsistent, out_inconsistent)

cat("Saved:", out_consistent, "\n")
cat("Saved:", out_inconsistent, "\n")

cat("Summary\n")
cat("  Total rows:", nrow(all_meta), "\n")
cat("  Successful:", nrow(successful), "\n")
cat("  Consistent:", nrow(consistent), "\n")
cat("  Inconsistent:", nrow(inconsistent), "\n")
cat("  Failed reads:", nrow(all_meta) - nrow(successful), "\n")
