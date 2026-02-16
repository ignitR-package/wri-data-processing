#!/usr/bin/env Rscript
# =============================================================================
# 02b_make_stac_all.R - Create STAC Catalog + Collection + Items for ALL COGs
#
# Purpose:
#   Build a STAC catalog that automatically detects which COGs are hosted on
#   KNB and uses the appropriate href for each item:
#     - If hosted on KNB: use KNB URL (for remote access)
#     - If not hosted: use local file path (for local development)
#
#   This script handles both local development and production workflows.
#   It enables gradual migration to hosted COGs without requiring all files
#   to be uploaded at once.
#
# Input:
#   - metadata/all_layers_consistent.csv (metadata from 00b)
#   - cogs/*.tif (local COG files)
#
# Output:
#   - stac/catalog.json
#   - stac/collections/<collection_id>/collection.json
#   - stac/collections/<collection_id>/items/<item_id>.json (one per COG)
#
# Usage:
#   Rscript scripts/02b_make_stac_all.R
#
# When to run:
#   - After creating COGs (01b)
#   - After uploading new COGs to KNB
#   - Before updating the fedex package with new STAC catalog
#
# Notes:
#   - Checks each file individually via HTTP HEAD request to KNB
#   - Uses KNB URL for hosted files, local path for non-hosted files
#   - Safe to re-run: skips existing STAC items
#   - Network-dependent: requires connection to KNB for status checks
# =============================================================================

library(readr)
library(dplyr)
library(sf)
library(fs)
library(jsonlite)
library(httr)

source("scripts/R/utils.R")

# --- Config -------------------------------------------------------------------

meta_csv <- "metadata/all_layers_consistent.csv"
cogs_dir <- "cogs"
stac_root <- "stac"
collection_id <- "wri_ignitR"

# Single datetime for all items (project due date)
item_datetime <- "2026-06-05T00:00:00Z"

# KNB base URL
knb_base_url <- "https://knb.ecoinformatics.org/data/"

# HTTP timeout for checking hosted files (seconds)
check_timeout <- 5

# --- Output paths -------------------------------------------------------------

collection_dir <- path(stac_root, "collections", collection_id)
items_dir <- path(collection_dir, "items")
dir_create(items_dir, recurse = TRUE)

catalog_path <- path(stac_root, "catalog.json")
collection_path <- path(collection_dir, "collection.json")

# --- Helper: Check if file is hosted on KNB ----------------------------------

#' Check if a COG file is accessible on KNB
#'
#' Uses HTTP HEAD request to check if file exists without downloading it.
#'
#' @param filename COG filename (e.g., "WRI_score.tif")
#' @param base_url Base URL for KNB data
#' @param timeout Timeout in seconds
#' @return Logical - TRUE if file is accessible, FALSE otherwise
check_knb_hosted <- function(filename, base_url, timeout = 5) {
  url <- paste0(base_url, filename)

  tryCatch({
    # Use HEAD request to check without downloading
    response <- HEAD(url, timeout(timeout))

    # Check if response is successful (200-299 status code)
    if (status_code(response) >= 200 && status_code(response) < 300) {
      return(TRUE)
    } else {
      return(FALSE)
    }
  }, error = function(e) {
    # Any error (timeout, connection refused, etc.) means not accessible
    return(FALSE)
  })
}

# --- Load and validate metadata -----------------------------------------------

if (!file_exists(meta_csv)) stop("Missing metadata CSV: ", meta_csv)

meta <- read_csv(meta_csv, show_col_types = FALSE)

# Check required columns exist
required_cols <- c(
  "filepath", "filename",
  "extent_xmin", "extent_xmax", "extent_ymin", "extent_ymax",
  "crs_epsg",
  "data_type", "wri_domain", "wri_dimension",
  "cog_filename"
)

missing <- setdiff(required_cols, names(meta))
if (length(missing) > 0) {
  stop("Metadata CSV missing required columns: ", paste(missing, collapse = ", "))
}

if (nrow(meta) == 0) stop("Metadata CSV is empty")

# Check for duplicate filenames
if (any(duplicated(meta$cog_filename))) {
  dup <- meta$cog_filename[duplicated(meta$cog_filename)][1]
  stop("Duplicate filename in metadata (cannot use as unique COG ID): ", dup)
}

# --- Collection spatial extent ------------------------------------------------
# Use first row since all extents are assumed consistent

spatial0 <- extent_to_stac_spatial(
  meta$extent_xmin[1], meta$extent_xmax[1],
  meta$extent_ymin[1], meta$extent_ymax[1]
)

# --- Check which files are hosted on KNB --------------------------------------

cat("\n=== Checking which files are hosted on KNB ===\n")
cat("This may take a minute...\n\n")

# Add a column to track hosting status
meta$is_hosted <- FALSE

for (i in seq_len(nrow(meta))) {
  filename <- meta$cog_filename[i]

  cat(sprintf("[%d/%d] Checking: %s ... ", i, nrow(meta), filename))

  is_hosted <- check_knb_hosted(filename, knb_base_url, check_timeout)
  meta$is_hosted[i] <- is_hosted

  cat(ifelse(is_hosted, "✓ HOSTED\n", "✗ not hosted\n"))
}

# Summary
n_hosted <- sum(meta$is_hosted)
n_local <- sum(!meta$is_hosted)

cat("\n=== Hosting Summary ===\n")
cat("  Total files:  ", nrow(meta), "\n")
cat("  Hosted on KNB:", n_hosted, "\n")
cat("  Local only:   ", n_local, "\n\n")

if (n_hosted > 0) {
  cat("Hosted files:\n")
  cat(paste("  -", meta$cog_filename[meta$is_hosted], collapse = "\n"), "\n\n")
}

# --- Build items --------------------------------------------------------------

n_total <- nrow(meta)
counts <- c(written = 0, skipped = 0, missing_cog = 0)

cat("Creating STAC items for", n_total, "files\n")
cat("Output directory:", stac_root, "\n\n")

for (i in seq_len(n_total)) {
  row <- meta[i, ]
  cog_path <- path(cogs_dir, row$cog_filename)

  # Skip if COG doesn't exist locally (may not have been converted yet)
  if (!file_exists(cog_path)) {
    cat(sprintf("[%d/%d] Missing COG, skipping: %s\n", i, n_total, row$cog_filename))
    counts["missing_cog"] <- counts["missing_cog"] + 1
    next
  }

  item_id <- tools::file_path_sans_ext(row$cog_filename)
  item_path <- path(items_dir, paste0(item_id, ".json"))

  # Skip if item already exists (allows resume)
  if (file_exists(item_path)) {
    cat(sprintf("[%d/%d] Item exists, skipping: %s\n", i, n_total, item_id))
    counts["skipped"] <- counts["skipped"] + 1
    next
  }

  cat(sprintf("[%d/%d] Writing item: %s ", i, n_total, item_id))

  # Transform extent to EPSG:4326 for STAC
  spatial <- extent_to_stac_spatial(
    row$extent_xmin, row$extent_xmax, row$extent_ymin, row$extent_ymax
  )

  # Determine asset href based on hosting status
  if (row$is_hosted) {
    # File is hosted on KNB - use URL for remote access
    asset_href <- paste0(knb_base_url, row$cog_filename)
    cat("(KNB URL)\n")
  } else {
    # File not hosted - use local path
    asset_href <- path_rel(cog_path, start = stac_root)
    cat("(local path)\n")
  }

  # Build STAC Item with WRI classification properties
  item <- list(
    stac_version = "1.0.0",
    stac_extensions = list("https://stac-extensions.github.io/projection/v1.1.0/schema.json"),
    type = "Feature",
    id = item_id,
    collection = collection_id,
    geometry = spatial$geometry,
    bbox = spatial$bbox,
    properties = list(
      datetime = item_datetime,

      # Projection extension
      "proj:code" = paste0("EPSG:", row$crs_epsg),

      # WRI-specific classification (enables filtering)
      data_type = row$data_type,
      wri_domain = row$wri_domain,
      wri_dimension = row$wri_dimension,

      # Custom property to track hosting status
      # This helps fedex package provide better error messages
      is_hosted = row$is_hosted
    ),
    assets = list(
      data = list(
        href = asset_href,  # *** KNB URL or local path ***
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

  write_json(item, item_path, auto_unbox = TRUE, pretty = TRUE)
  counts["written"] <- counts["written"] + 1
}

# --- Build catalog and collection ---------------------------------------------
# These are written every run (cheap to regenerate)

catalog <- list(
  stac_version = "1.0.0",
  type = "Catalog",
  id = "wri-catalog",
  title = "WRI Wildfire Resilience Index",
  description = "WRI raster layers as Cloud Optimized GeoTIFFs (COGs)",
  links = list(
    list(rel = "self", href = "catalog.json", type = "application/json"),
    list(rel = "child", href = path_rel(collection_path, start = stac_root), type = "application/json")
  )
)

collection <- list(
  stac_version = "1.0.0",
  stac_extensions = list("https://stac-extensions.github.io/projection/v1.1.0/schema.json"),
  type = "Collection",
  id = collection_id,
  title = "WRI ignitR Dataset",
  description = "WRI raster layers (COGs)",
  license = "proprietary",
  extent = list(
    spatial = list(bbox = list(spatial0$bbox)),
    temporal = list(interval = list(list(item_datetime, item_datetime)))
  ),
  summaries = list(
    data_type = list("aggregate", "final_score", "indicator"),
    wri_domain = list(
      "air_quality", "communities", "iconic_places", "iconic_species",
      "infrastructure", "livelihoods", "natural_habitats", "sense_of_place",
      "species", "unknown", "water"
    ),
    wri_dimension = list("domain_score", "recovery", "resilience", "resistance", "status"),
    "proj:code" = list("EPSG:5070")
  ),
  links = list(
    list(rel = "self", href = path_rel(collection_path, start = stac_root), type = "application/json"),
    list(rel = "root", href = "catalog.json", type = "application/json"),
    list(rel = "parent", href = "catalog.json", type = "application/json")
  )
)

write_json(catalog, catalog_path, auto_unbox = TRUE, pretty = TRUE)
write_json(collection, collection_path, auto_unbox = TRUE, pretty = TRUE)

# --- Summary ------------------------------------------------------------------

cat("\n")
cat("=== STAC Creation Summary ===\n")
cat("  Catalog:        ", catalog_path, "\n")
cat("  Collection:     ", collection_path, "\n")
cat("  Items dir:      ", items_dir, "\n")
cat("  Asset hrefs:     Mixed (", n_hosted, " KNB URLs, ", n_local, " local paths)\n")
cat("  Total in meta:  ", n_total, "\n")
cat("  Written:        ", counts["written"], "\n")
cat("  Skipped (exist):", counts["skipped"], "\n")
cat("  Missing COG:    ", counts["missing_cog"], "\n\n")

cat("Next steps:\n")
cat("  1. Copy STAC to fedex package:\n")
cat("     cp -r", stac_root, "fedex/inst/extdata/\n\n")
cat("  2. Test in fedex package:\n")
cat("     devtools::load_all(\"fedex\")\n")
cat("     items <- load_stac_items()\n")
cat("     # Try a hosted file:\n")
cat("     get_layer(\"WRI_score\", bbox = c(-122, 37, -121, 38))\n\n")

if (n_local > 0) {
  cat("⚠️  Note: ", n_local, " files have local paths and cannot be accessed remotely.\n")
  cat("   The fedex package will show appropriate error messages for these.\n")
  cat("   Once files are uploaded to KNB, rerun this script to update the STAC.\n")
}
