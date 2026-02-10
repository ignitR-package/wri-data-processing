# =============================================================================
# Script: scratch/02a_make_stac_one.R
# Purpose: Prototype for creating STAC metadata for a single COG
# Author: ignitR Team (Emily, Ixel, Kaiju, Hylaea)
# Created: January 2025
# Last Modified: January 2025
#
# Description:
#   This is a development/testing script for working through STAC catalog
#   creation on a single COG. Creates a minimal but valid STAC structure
#   with a Catalog, Collection, and one Item.
#
# What this script does:
#   - Creates a STAC Catalog (stac/catalog.json)
#   - Creates a STAC Collection (stac/collections/wri_ignitR/collection.json)
#   - Creates one STAC Item with spatial extent and asset link
#
# What this script does NOT do:
#   - Process multiple COGs
#   - Read from conversion logs
#   - Compute collection-wide extent from multiple items
#
# Why this script exists:
#   Use this to test STAC metadata structure and validate the output
#   before running the full batch process (scripts/02a_make_stac_one.R).
#
# Inputs:
#   - One COG file (configured via `cog_path` variable below)
#
# Outputs:
#   - stac/catalog.json
#   - stac/collections/wri_ignitR/collection.json
#   - stac/collections/wri_ignitR/items/<item_id>.json
#
# Dependencies:
#   - terra, sf, fs, jsonlite
#   - scripts/R/utils.R (shared helper functions)
#
# Usage:
#   1. Set `cog_path` to the COG you want to create STAC metadata for
#   2. source("scratch/02a_make_stac_one.R")
# =============================================================================


# Setup ----------------------------------------------------------------------

library(terra)
library(sf)
library(fs)
library(jsonlite)

# Load shared helper functions
source("scripts/R/utils.R")


# Config ---------------------------------------------------------------------

# >>> CHANGE THIS to test different COGs <<<
cog_path <- "cogs/livelihoods_domain_score.tif"

# STAC structure
stac_root <- "stac"
collection_id <- "wri_ignitR"

# Item ID derived from filename
item_id <- make_item_id(cog_path)

# Publication datetime (required STAC field)
item_datetime <- "2026-06-05T00:00:00Z"

# COG settings for documentation
cog_blocksize <- 512
cog_compress <- "DEFLATE"
cog_overview_resampling <- "AVERAGE"  # Change if testing a status layer


# Output paths ---------------------------------------------------------------

catalog_path <- path(stac_root, "catalog.json")
collection_dir <- path(stac_root, "collections", collection_id)
collection_path <- path(collection_dir, "collection.json")
items_dir <- path(collection_dir, "items")
item_path <- path(items_dir, paste0(item_id, ".json"))

# Create directories
dir_create(items_dir, recurse = TRUE)


# Verify COG exists ----------------------------------------------------------

if (!file_exists(cog_path)) {
  stop(paste("COG not found:", cog_path,
             "\nRun scratch/01a_make_cog_one.R first."))
}

cat("=== STAC Creation Test ===\n\n")
cat("COG:", cog_path, "\n")
cat("Item ID:", item_id, "\n\n")


# Extract spatial metadata ---------------------------------------------------

cat("Extracting spatial metadata...\n")

# Use the shared function from utils.R
spatial <- get_item_spatial(cog_path)

cat("Native EPSG:", spatial$proj_epsg, "\n")
cat("Bbox (WGS84):", paste(round(spatial$bbox, 4), collapse = ", "), "\n\n")


# Build STAC objects ---------------------------------------------------------

cat("Building STAC objects...\n\n")

# Root Catalog
catalog <- list(
  stac_version = "1.0.0",
  type = "Catalog",
  id = "wri-catalog",
  description = "WRI raster layers as Cloud-Optimized GeoTIFFs (COGs)",
  links = list(
    list(rel = "self", href = "catalog.json", type = "application/json"),
    list(rel = "child", href = path_rel(collection_path, start = stac_root), type = "application/json")
  )
)

# Collection (extent based on this single item)
collection <- list(
  stac_version = "1.0.0",
  type = "Collection",
  id = collection_id,
  title = "Wildfire Resilience Index (WRI)",
  description = "Cloud-Optimized GeoTIFF versions of the Wildfire Resilience Index dataset.",
  license = "proprietary",
  extent = list(
    spatial = list(bbox = list(spatial$bbox)),
    temporal = list(interval = list(list(item_datetime, item_datetime)))
  ),
  links = list(
    list(rel = "self", href = path_rel(collection_path, start = stac_root), type = "application/json"),
    list(rel = "root", href = "catalog.json", type = "application/json"),
    list(rel = "parent", href = "catalog.json", type = "application/json"),
    list(rel = "item", href = path_rel(item_path, start = stac_root), type = "application/geo+json")
  )
)

# Item
item <- list(
  stac_version = "1.0.0",
  type = "Feature",
  id = item_id,
  geometry = spatial$geometry,
  bbox = spatial$bbox,
  properties = list(
    datetime = item_datetime,
    
    # Note: These would come from metadata in production
    # Leaving as examples for the prototype
    data_type = "aggregate",
    domain = "livelihoods",
    layer_type = "domain_score",
    
    # Document COG creation parameters
    "cog:blocksize" = cog_blocksize,
    "cog:compression" = cog_compress,
    "cog:overview_resampling" = cog_overview_resampling,
    
    # Projection info
    "proj:epsg" = spatial$proj_epsg
  ),
  assets = list(
    data = list(
      # Local relative path - update with KNB URLs after archiving
      href = path_rel(cog_path, start = stac_root),
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


# Write JSON files -----------------------------------------------------------

write_json(catalog, catalog_path, auto_unbox = TRUE, pretty = TRUE)
write_json(collection, collection_path, auto_unbox = TRUE, pretty = TRUE)
write_json(item, item_path, auto_unbox = TRUE, pretty = TRUE)

cat("=== Files Written ===\n")
cat("Catalog:   ", catalog_path, "\n")
cat("Collection:", collection_path, "\n")
cat("Item:      ", item_path, "\n\n")


# Preview item JSON ----------------------------------------------------------

cat("=== Item JSON Preview ===\n")
cat(toJSON(item, auto_unbox = TRUE, pretty = TRUE), "\n")