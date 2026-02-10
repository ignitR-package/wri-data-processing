# =============================================================================
# Script: scratch/00a_extract_metadata_one.R
# Purpose: Prototype for extracting metadata from a single WRI GeoTIFF
# Author: ignitR Team (Emily, Ixel, Kaiju, Hylaea)
# Created: January 2025
# Last Modified: January 2025
#
# Description:
#   This is a development/testing script for working through the metadata
#   extraction logic on a single file before scaling to the full dataset.
#   It prints results to the console rather than saving to CSV.
#
# What this script does:
#   - Reads one GeoTIFF layer from disk
#   - Extracts basic raster metadata (dimensions, resolution, CRS, extent)
#   - Computes simple value summaries (min, max, mean, NA percent)
#   - Classifies the layer by data type, domain, and layer type
#
# Why this script exists:
#   Use this to test and debug metadata extraction logic on individual files
#   before running the full batch process (scripts/00a_extract_metadata_one.R).
#
# Inputs:
#   - One GeoTIFF file (configured via `test_file` variable below)
#
# Outputs:
#   - Console output only
#
# Dependencies:
#   - terra, dplyr, fs
#   - scripts/R/utils.R (shared helper functions)
#
# Usage:
#   1. Set `test_file` to the path of the layer you want to test
#   2. source("scratch/00a_extract_metadata_one.R")
# =============================================================================


# Setup ----------------------------------------------------------------------

library(terra)
library(dplyr)
library(fs)

# Load shared helper functions
source("scripts/R/utils.R")


# Config ---------------------------------------------------------------------

test_file <- "data/livelihoods/livelihoods_domain_score.tif"


# Extract metadata -----------------------------------------------------------

cat("Testing metadata extraction for:\n")
cat(" ", test_file, "\n\n")

if (!file_exists(test_file)) {
  stop(paste("File not found:", test_file))
}

# Use the shared function from utils.R
metadata <- get_raster_info(test_file)

if (!metadata$success) {
  stop(paste("Failed to read file:", metadata$error))
}

cat("Successfully read file\n\n")


# Classify file --------------------------------------------------------------

# Determine data type from path/filename
data_type <- case_when(
  grepl("/indicators/", metadata$filepath) ~ "indicator",
  grepl("WRI_score\\.tif$", metadata$filepath) ~ "final_score",
  grepl("_(domain_score|resilience|resistance|status)\\.tif$", metadata$filepath) ~ "aggregate",
  TRUE ~ "unknown"
)

# Extract domain using shared function
domain <- if (data_type == "final_score") {
  "all_domains"
} else {
  extract_domain(metadata$filepath)
}

# Determine layer type
layer_type <- case_when(
  # Indicators
  data_type == "indicator" & grepl("_resistance_", metadata$filename) ~ "resistance",
  data_type == "indicator" & grepl("_recovery_", metadata$filename) ~ "recovery",
  data_type == "indicator" & grepl("_status_", metadata$filename) ~ "status",
  
  # Aggregates
  data_type == "aggregate" & grepl("domain_score", metadata$filename) ~ "domain_score",
  data_type == "aggregate" & grepl("resilience", metadata$filename) ~ "resilience",
  data_type == "aggregate" & grepl("resistance", metadata$filename) ~ "resistance",
  data_type == "aggregate" & grepl("status", metadata$filename) ~ "status",
  
  # Final score has no layer type
  TRUE ~ NA_character_
)


# Display results ------------------------------------------------------------

cat("=== File Classification ===\n")
cat("Data type:", data_type, "\n")
cat("Domain:", domain, "\n")
if (!is.na(layer_type)) {
  cat("Layer type:", layer_type, "\n")
}
cat("\n")

cat("=== File Info ===\n")
cat("Filename:", metadata$filename, "\n")
cat("Size:", metadata$file_size_mb, "MB\n")
cat("Raster datatype:", metadata$datatype, "\n\n")

cat("=== Dimensions ===\n")
cat("Rows:", metadata$nrows, "\n")
cat("Cols:", metadata$ncols, "\n")
cat("Cells:", format(metadata$ncells, big.mark = ","), "\n")
cat("Layers:", metadata$nlayers, "\n\n")

cat("=== Resolution ===\n")
cat("X:", metadata$resolution_x, "\n")
cat("Y:", metadata$resolution_y, "\n\n")

cat("=== CRS ===\n")
cat("Code:", metadata$crs, "\n\n")

cat("=== Extent ===\n")
cat("X range:", metadata$extent_xmin, "to", metadata$extent_xmax, "\n")
cat("Y range:", metadata$extent_ymin, "to", metadata$extent_ymax, "\n\n")

cat("=== Data Values ===\n")
cat("Value range:", metadata$value_min, "to", metadata$value_max, "\n")
cat("Mean:", round(metadata$value_mean, 4), "\n")
cat("Missing data:", metadata$na_percent, "%\n\n")

cat("=== COG Recommendation ===\n")
resampling <- choose_resampling(layer_type, metadata$datatype)
cat("Suggested overview resampling:", resampling, "\n")