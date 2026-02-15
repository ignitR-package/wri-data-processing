# =============================================================================
# 02b_make_stac_all.R - Create STAC Catalog + Collection + Items for ALL COGs
#
# Purpose:
#   Build a complete STAC catalog with one collection containing items for
#   all COG files. Each item includes WRI classification properties to enable
#   filtering by domain, data_type, and layer_type.
#
# Input:
#   - metadata/all_layers_consistent.csv (metadata from 00b)
#   - cogs/*.tif (COGs from 01b)
#
# Output:
#   - stac/catalog.json
#   - stac/collections/<collection_id>/collection.json
#   - stac/collections/<collection_id>/items/<item_id>.json (one per COG)
#
# Notes:
#   - Does NOT read raster files; all info comes from metadata CSV.
#   - STAC spatial info is in EPSG:4326 (transformed from 5070).
#   - Rerun-safe: skips items that already exist.
# =============================================================================

library(readr)
library(dplyr)
library(sf)
library(fs)
library(jsonlite)

source("scripts/R/utils.R")

# --- Config -------------------------------------------------------------------

meta_csv <- "metadata/all_layers_consistent.csv"
cogs_dir <- "cogs"
stac_root <- "stac"
collection_id <- "wri_ignitR"

# Single datetime for all items (project due date)
item_datetime <- "2026-06-05T00:00:00Z"

# --- Output paths -------------------------------------------------------------

collection_dir <- path(stac_root, "collections", collection_id)
items_dir <- path(collection_dir, "items")
dir_create(items_dir, recurse = TRUE)

catalog_path <- path(stac_root, "catalog.json")
collection_path <- path(collection_dir, "collection.json")

# --- Load and validate metadata -----------------------------------------------

if (!file_exists(meta_csv)) stop("Missing metadata CSV: ", meta_csv)

meta <- read_csv(meta_csv, show_col_types = FALSE)

# Check required columns exist
required_cols <- c(
  "filepath", "filename", 
  "extent_xmin", "extent_xmax", "extent_ymin", "extent_ymax", 
  "crs_epsg",
  "data_type", "wri_domain", "wri_layer_type", "required_cols"
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

# --- Build items --------------------------------------------------------------

n_total <- nrow(meta)
counts <- c(written = 0, skipped = 0, missing_cog = 0)

cat("Creating STAC items for", n_total, "files\n")
cat("Output directory:", stac_root, "\n\n")

for (i in seq_len(n_total)) {
  row <- meta[i, ]
  cog_path <- path(cogs_dir, row$cog_filename)
  
  # Skip if COG doesn't exist (may not have been converted yet)
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
  
  cat(sprintf("[%d/%d] Writing item: %s\n", i, n_total, item_id))
  
  # Transform extent to EPSG:4326 for STAC
  spatial <- extent_to_stac_spatial(
    row$extent_xmin, row$extent_xmax, row$extent_ymin, row$extent_ymax
  )
  
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
      wri_layer_type = row$wri_layer_type
    ),
    assets = list(
      data = list(
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
    wri_layer_type = list("domain_score", "recovery", "resilience", "resistance", "status"),
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
cat("  Total in meta:  ", n_total, "\n")
cat("  Written:        ", counts["written"], "\n")
cat("  Skipped (exist):", counts["skipped"], "\n")
cat("  Missing COG:    ", counts["missing_cog"], "\n")