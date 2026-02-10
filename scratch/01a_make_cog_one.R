# =============================================================================
# Script: scratch/01a_make_cog_one.R
# Purpose: Prototype for converting a single GeoTIFF to Cloud-Optimized GeoTIFF
# Author: ignitR Team (Emily, Ixel, Kaiju, Hylaea)
# Created: January 2025
# Last Modified: January 2025
#
# Description:
#   This is a development/testing script for working through COG conversion
#   on a single file. Use this to verify GDAL settings and inspect the output
#   before running the full batch conversion.
#
# What this script does:
#   - Converts one GeoTIFF to a Cloud-Optimized GeoTIFF (COG)
#   - Uses DEFLATE compression with 512x512 tiles
#   - Builds internal overviews with appropriate resampling
#
# What this script does NOT do:
#   - Process multiple files
#   - Create organized output directories
#   - Write conversion logs
#
# Why this script exists:
#   Use this to test COG conversion settings on individual files before
#   running the full batch process (scripts/01a_make_cog_one.R).
#
# Inputs:
#   - One GeoTIFF file (configured via `input_tif` variable below)
#
# Outputs:
#   - One COG file in the `cogs/` directory
#
# Dependencies:
#   - fs
#   - GDAL (gdal_translate and gdalinfo must be available on PATH)
#   - scripts/R/utils.R (shared helper functions)
#
# Usage:
#   1. Set `input_tif` to the path of the layer you want to convert
#   2. Set `resampling_method` (or leave as "auto" to detect)
#   3. source("scratch/01a_make_cog_one.R")
# =============================================================================


# Setup ----------------------------------------------------------------------

library(fs)

# Load shared helper functions (for choose_resampling)
source("scripts/R/utils.R")


# Config ---------------------------------------------------------------------

# >>> CHANGE THIS to test different files <<<
input_tif <- "data/livelihoods/livelihoods_domain_score.tif"

# Output directory and file
output_dir <- "cogs"
output_cog <- path(output_dir, path_file(input_tif))

# Resampling method for overviews
# Options: "AVERAGE" (continuous), "NEAREST" (categorical), or "auto"
resampling_method <- "auto"

# COG conversion settings
blocksize <- 512
compression <- "DEFLATE"
max_threads <- 50


# Verify input exists --------------------------------------------------------

if (!file_exists(input_tif)) {
  stop(paste("Input file not found:", input_tif))
}

cat("=== COG Conversion Test ===\n\n")
cat("Input:", input_tif, "\n")
cat("Output:", output_cog, "\n\n")


# Determine resampling method ------------------------------------------------

if (resampling_method == "auto") {
  # Try to determine from the filename
  filename <- basename(input_tif)
  
  # Check if it's a status layer (categorical)
  if (grepl("_status", filename)) {
    resampling_method <- "NEAREST"
  } else {
    resampling_method <- "AVERAGE"
  }
  
  cat("Auto-detected resampling method:", resampling_method, "\n\n")
} else {
  cat("Using specified resampling method:", resampling_method, "\n\n")
}


# Check if output already exists ---------------------------------------------

dir_create(output_dir)

if (file_exists(output_cog)) {
  cat("COG already exists. Skipping conversion.\n")
  cat("Delete the existing file to re-run:\n")
  cat("  ", output_cog, "\n")
} else {
  
  # Build and run gdal_translate command -------------------------------------
  
  cmd <- paste(
    "gdal_translate",
    "-of COG",
    paste0("-co COMPRESS=", compression),
    "-co PREDICTOR=YES",
    paste0("-co BLOCKSIZE=", blocksize),
    paste0("-co RESAMPLING=", resampling_method),
    "-co OVERVIEWS=IGNORE_EXISTING",
    paste0("-co NUM_THREADS=", max_threads),
    shQuote(input_tif),
    shQuote(output_cog)
  )
  
  cat("Running command:\n")
  cat(cmd, "\n\n")
  
  # Execute
  result <- system(cmd)
  
  if (result != 0) {
    stop("gdal_translate failed with exit code ", result)
  }
  
  cat("\nConversion complete!\n")
}


# Verify output --------------------------------------------------------------

if (file_exists(output_cog)) {
  cat("\n=== Output File Info ===\n")
  
  input_size <- file_size(input_tif)
  output_size <- file_size(output_cog)
  compression_ratio <- round(as.numeric(input_size) / as.numeric(output_size), 2)
  
  cat("Input size:", round(input_size / (2^20), 2), "MB\n")
  cat("Output size:", round(output_size / (2^20), 2), "MB\n")
  cat("Compression ratio:", compression_ratio, "x\n\n")
  
  # Run gdalinfo to verify COG structure
  cat("=== COG Validation (gdalinfo) ===\n")
  system(paste("gdalinfo", shQuote(output_cog), "| head -30"))
}