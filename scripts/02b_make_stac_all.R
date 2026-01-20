# =============================================================================
# Script: 02b_make_stac_all.R
# Purpose: Create STAC Catalog, Collection, and Items for all WRI COGs
# Author: ignitR Team (Emily, Ixel, Kaiju, Hylaea)
# Created: January 2025
# Last Modified: January 2025
#
# Description:
#   This script generates a SpatioTemporal Asset Catalog (STAC) for the WRI
#   COG collection. STAC is a standard for describing geospatial data that
#   enables discovery and access through consistent metadata.
#
#   The script creates:
#   - One root Catalog (stac/catalog.json)
#   - One Collection containing all WRI layers (stac/collections/wri_ignitR/)
#   - One Item per COG with spatial extent, properties, and asset links
#
# Inputs:
#   - outputs/validation_reports/cog_conversion_log.csv (from 01b_make_cog_all.R)
#   - COG files in cogs/ directory
#
# Outputs:
#   - stac/catalog.json
#   - stac/collections/wri_ignitR/collection.json
#   - stac/collections/wri_ignitR/items/<item_id>.json
#
# Dependencies:
#   - readr, dplyr, terra, sf, fs, jsonlite
#   - scripts/R/utils.R (shared helper functions)
#
# Usage:
#   source("scripts/02b_make_stac_all.R")
#
# Notes:
#   - Safe to re-run: existing items are skipped
#   - Asset hrefs are currently relative paths (update with KNB URLs later)
#   - All items share a single publication datetime
#   - Progress is saved every 25 items
# =============================================================================


# Setup ----------------------------------------------------------------------

library(readr)
library(dplyr)
library(terra)
library(sf)
library(fs)
library(jsonlite)

# Load shared helper functions
source("scripts/R/utils.R")


# Config ---------------------------------------------------------------------

# Input: conversion log from step 01
log_path <- "outputs/validation_reports/cog_conversion_log.csv"

# STAC output structure
stac_root <- "stac"
collection_id <- "wri_ignitR"

# Publication datetime (required STAC field)
# Using a fixed date representing when the dataset will be published
item_datetime <- "2026-06-05T00:00:00Z"

# COG conversion settings (for documentation in STAC properties)
cog_blocksize <- 512
cog_compress <- "DEFLATE"


# Output paths ---------------------------------------------------------------

catalog_path <- path(stac_root, "catalog.json")
collection_dir <- path(stac_root, "collections", collection_id)
collection_path <- path(collection_dir, "collection.json")
items_dir <- path(collection_dir, "items")

# Create directory structure
dir_create(items_dir, recurse = TRUE)


# Read conversion log --------------------------------------------------------

if (!file_exists(log_path)) {
  stop(paste("Missing conversion log:", log_path,
             "\nRun 01b_make_cog_all.R first."))
}

log_df <- read_csv(log_path, show_col_types = FALSE)

# Keep only successfully converted COGs
log_df <- log_df |>
  filter(status %in% c("converted", "skipped_exists"))

if (nrow(log_df) == 0) {
  stop("No usable COGs found in conversion log.")
}

cat("Found", nrow(log_df), "COGs to create STAC items for\n")


# Build items ----------------------------------------------------------------

all_bboxes <- list()
items_written <- 0
items_skipped <- 0

for (i in seq_len(nrow(log_df))) {
  
  cog_out <- log_df$output[i]
  
  # Verify COG exists
  if (!file_exists(cog_out)) {
    cat("Missing COG, skipping:", cog_out, "\n")
    next
  }
  
  # Generate item ID and path
  item_id <- make_item_id(cog_out)
  item_path <- path(items_dir, paste0(item_id, ".json"))
  
  # Skip if item already exists (re-run safety)
  if (file_exists(item_path)) {
    cat(sprintf("[%d/%d] Item exists, skipping: %s\n", i, nrow(log_df), item_id))
    items_skipped <- items_skipped + 1
    next
  }
  
  cat(sprintf("[%d/%d] Writing item: %s\n", i, nrow(log_df), item_id))
  
  # Extract spatial metadata using shared function
  spatial <- get_item_spatial(cog_out)
  all_bboxes[[length(all_bboxes) + 1]] <- spatial$bbox
  
  # Get optional metadata fields from log
  data_type <- if ("data_type" %in% names(log_df)) log_df$data_type[i] else NA
  domain <- if ("domain" %in% names(log_df)) log_df$domain[i] else NA
  layer_type <- if ("layer_type" %in% names(log_df)) log_df$layer_type[i] else NA
  overview_resampling <- if ("resampling" %in% names(log_df)) log_df$resampling[i] else NA
  
  # Build STAC Item
  item <- list(
    stac_version = "1.0.0",
    type = "Feature",
    id = item_id,
    geometry = spatial$geometry,
    bbox = spatial$bbox,
    properties = list(
      datetime = item_datetime,
      
      # WRI-specific classification
      data_type = data_type,
      domain = domain,
      layer_type = layer_type,
      
      # COG creation parameters (for reproducibility)
      "cog:blocksize" = cog_blocksize,
      "cog:compression" = cog_compress,
      "cog:overview_resampling" = overview_resampling,
      
      # Projection info
      "proj:epsg" = spatial$proj_epsg
    ),
    assets = list(
      data = list(
        # Local relative path - will be updated with KNB URLs after archiving
        href = path_rel(cog_out, start = stac_root),
        type = "image/tiff; application=geotiff; profile=cloud-optimized",
        roles = list("data"),
        title = "COG"
      )
    ),
    links = list(
      list(rel = "self", href = path_rel(item_path, start = stac_root), type = "application/geo+json"),
      list(rel = "root", href = "catalog.json", type = "application/json"),
      list(rel = "parent", href = path_rel(collection_path, start = stac_root), type = "application/json"),
      list(rel = "collection", href = path_rel(collection_path, start = stac_root), type = "application/json")
    )
  )
  
  # Write item JSON
  write_json(item, item_path, auto_unbox = TRUE, pretty = TRUE)
  
  items_written <- items_written + 1
  
  # Progress checkpoint every 25 items
  if (items_written %% 25 == 0) {
    cat("  [checkpoint:", items_written, "items written]\n")
  }
}

# Verify we have bboxes to build collection extent
if (length(all_bboxes) == 0 && items_written == 0) {
  cat("Warning: No new items written. Checking for existing items...\n")
  
  # Try to read bboxes from existing items
  existing_items <- dir_ls(items_dir, glob = "*.json")
  if (length(existing_items) > 0) {
    for (item_file in existing_items) {
      item_json <- read_json(item_file)
      if (!is.null(item_json$bbox)) {
        all_bboxes[[length(all_bboxes) + 1]] <- unlist(item_json$bbox)
      }
    }
    cat("Loaded bboxes from", length(all_bboxes), "existing items\n")
  }
}

if (length(all_bboxes) == 0) {
  stop("No bboxes collected. Cannot build collection extent.")
}


# Build Catalog and Collection -----------------------------------------------

# Compute collection bbox as union of all item bboxes
collection_bbox <- bbox_union(all_bboxes)

# Root Catalog
catalog <- list(
  stac_version = "1.0.0",
  type = "Catalog",
  id = "wri-catalog",
  description = "Wildfire Resilience Index (WRI) raster layers as Cloud-Optimized GeoTIFFs (COGs)",
  links = list(
    list(rel = "self", href = "catalog.json", type = "application/json"),
    list(rel = "child", href = path_rel(collection_path, start = stac_root), type = "application/json")
  )
)

# Collection
collection <- list(
  stac_version = "1.0.0",
  type = "Collection",
  id = collection_id,
  title = "Wildfire Resilience Index (WRI)",
  description = paste(
    "Cloud-Optimized GeoTIFF versions of the Wildfire Resilience Index dataset.",
    "The WRI measures wildfire resilience across eight domains including",
    "Infrastructure, Communities, Livelihoods, Sense of Place, Species,",
    "Habitats, Water, and Air."
  ),
  license = "proprietary",
  extent = list(
    spatial = list(bbox = list(collection_bbox)),
    temporal = list(interval = list(list(item_datetime, item_datetime)))
  ),
  links = list(
    list(rel = "self", href = path_rel(collection_path, start = stac_root), type = "application/json"),
    list(rel = "root", href = "catalog.json", type = "application/json"),
    list(rel = "parent", href = "catalog.json", type = "application/json")
  )
)

# Write catalog and collection
write_json(catalog, catalog_path, auto_unbox = TRUE, pretty = TRUE)
write_json(collection, collection_path, auto_unbox = TRUE, pretty = TRUE)


# Summary --------------------------------------------------------------------

cat("\n--- Done ---\n")
cat("Wrote catalog:    ", catalog_path, "\n")
cat("Wrote collection: ", collection_path, "\n")
cat("Items directory:  ", items_dir, "\n")
cat("\nItems written:  ", items_written, "\n")
cat("Items skipped:  ", items_skipped, "\n")
cat("Total items:    ", length(dir_ls(items_dir, glob = "*.json")), "\n")