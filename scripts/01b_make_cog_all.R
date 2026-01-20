# =============================================================================
# Script: 01b_make_cog_all.R
# Purpose: Convert all consistent WRI GeoTIFFs to Cloud-Optimized GeoTIFFs (COGs)
# Author: ignitR Team (Emily, Ixel, Kaiju, Hylaea)
# Created: January 2025
# Last Modified: January 2025
#
# Description:
#   This script reads the clean metadata inventory produced by 00b_extract_metadata_all.R
#   and converts each GeoTIFF to a Cloud-Optimized GeoTIFF (COG). COGs enable
#   efficient remote access by organizing data into tiles with internal overviews.
#
#   The script automatically selects the appropriate overview resampling method:
#   - NEAREST for categorical data (status layers, integers)
#   - AVERAGE for continuous data (scores, indices)
#
# Inputs:
#   - config/all_layers_metadata.csv (from 00b_extract_metadata_all.R)
#
# Outputs:
#   - cogs/<data_type>/<domain>/<filename>.tif
#   - outputs/validation_reports/cog_conversion_log.csv
#
# Dependencies:
#   - readr, dplyr, fs
#   - GDAL (gdal_translate must be available on PATH)
#   - scripts/R/utils.R (shared helper functions)
#
# Usage:
#   source("scripts/01b_make_cog_all.R")
#
# Notes:
#   - Safe to re-run: existing COGs are skipped
#   - Progress is saved every 25 files
#   - Uses up to 50 threads (configurable via max_threads)
#   - COG settings: DEFLATE compression, 512x512 tiles, internal overviews
# =============================================================================


# Setup ----------------------------------------------------------------------

library(readr)
library(dplyr)
library(fs)

# Load shared helper functions
source("scripts/R/utils.R")


# Config ---------------------------------------------------------------------

# Input: clean metadata from step 00b
metadata_path <- "config/all_layers_metadata.csv"

# Output directories
cog_root <- "cogs"
log_path <- "outputs/validation_reports/cog_conversion_log.csv"

# Cluster resource limits
max_threads <- 50

# Create output directories
dir_create(cog_root)
dir_create(path_dir(log_path))


# Read metadata --------------------------------------------------------------

if (!file_exists(metadata_path)) {
  stop(paste("Missing metadata file:", metadata_path,
             "\nRun 00b_extract_metadata_all.R first."))
}

meta <- read_csv(metadata_path, show_col_types = FALSE)

# Validate required columns
if (!("filepath" %in% names(meta))) {
  stop("Metadata is missing required column: filepath")
}

if (!("layer_name" %in% names(meta)) && !("filename" %in% names(meta))) {
  cat("Note: metadata has no filename/layer_name column, using basename(filepath)\n")
}

# Check for optional columns we'll use
has_data_type <- "data_type" %in% names(meta)
has_domain <- "domain" %in% names(meta)
has_layer_type <- "layer_type" %in% names(meta)
has_datatype <- "datatype" %in% names(meta)

cat("Found", nrow(meta), "layers to process\n")


# Helper: Build output path --------------------------------------------------

#' Build COG output path with organized directory structure
#'
#' Creates path: cogs/<data_type>/<domain>/<basename>.tif
#' Also creates the directory if it doesn't exist.
make_out_path <- function(data_type, domain, in_path) {
  out_dir <- path(cog_root, data_type, domain)
  dir_create(out_dir)
  path(out_dir, path_file(in_path))
}


# Batch conversion -----------------------------------------------------------

results <- vector("list", nrow(meta))

for (i in seq_len(nrow(meta))) {
  
  in_path <- meta$filepath[i]
  
  # Get classification labels (with fallbacks)
  data_type <- if (has_data_type) meta$data_type[i] else "unknown"
  domain <- if (has_domain) meta$domain[i] else "unknown"
  layer_type <- if (has_layer_type) meta$layer_type[i] else NA
  datatype_str <- if (has_datatype) meta$datatype[i] else NA
  
  # Choose resampling method using shared function
  resampling <- choose_resampling(layer_type, datatype_str)
  
  # Build output path
  out_path <- make_out_path(data_type, domain, in_path)
  
  # Progress display
  cat(sprintf("[%d/%d] %s -> %s\n", i, nrow(meta), path_file(in_path), resampling))
  
  status <- "unknown"
  message <- ""
  
  # Skip if COG already exists
  if (file_exists(out_path)) {
    status <- "skipped_exists"
    message <- "COG already exists"
  } else {
    
    # Build gdal_translate command
    # Options explained:
    #   -of COG              Output format: Cloud-Optimized GeoTIFF
    #   COMPRESS=DEFLATE     Lossless compression, good balance of speed/size
    #   PREDICTOR=YES        Improves compression for continuous data
    #   BLOCKSIZE=512        512x512 pixel tiles (standard for COGs)
    #   RESAMPLING=...       Method for building overviews
    #   OVERVIEWS=IGNORE_... Rebuild overviews fresh
    #   NUM_THREADS=50       Parallel processing threads
    cmd <- paste(
      "gdal_translate",
      "-of COG",
      "-co COMPRESS=DEFLATE",
      "-co PREDICTOR=YES",
      "-co BLOCKSIZE=512",
      paste0("-co RESAMPLING=", resampling),
      "-co OVERVIEWS=IGNORE_EXISTING",
      paste0("-co NUM_THREADS=", max_threads),
      shQuote(in_path),
      shQuote(out_path)
    )
    
    # Execute conversion
    out <- try(system(cmd, intern = TRUE), silent = TRUE)
    
    if (inherits(out, "try-error")) {
      status <- "failed"
      message <- as.character(out)
    } else {
      status <- "converted"
      message <- "ok"
    }
  }
  
  # Record result
  results[[i]] <- tibble(
    i = i,
    input = in_path,
    output = out_path,
    data_type = data_type,
    domain = domain,
    layer_type = layer_type,
    datatype = datatype_str,
    resampling = resampling,
    status = status,
    message = message
  )
  
  # Save progress every 25 files
  if (i %% 25 == 0) {
    temp_log <- bind_rows(results[1:i])
    write_csv(temp_log, log_path)
    cat("  [checkpoint saved]\n")
  }
}


# Write final log ------------------------------------------------------------

log_df <- bind_rows(results)
write_csv(log_df, log_path)

cat("\n--- Done ---\n")
cat("Log saved:", log_path, "\n\n")

cat("Status summary:\n")
print(log_df %>% count(status))

cat("\nResampling summary:\n")
print(log_df %>% count(resampling, status))