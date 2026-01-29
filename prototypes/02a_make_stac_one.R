# =============================================================================
# 02a_make_stac_one.R - Create STAC Catalog + Collection + Item for ONE COG
#
# Input:  metadata/all_layers_consistent.csv, cogs/<filename>.tif
# Output: scratch_output/stac/catalog.json, collection.json, item.json
# =============================================================================

library(sf)
library(fs)
library(jsonlite)
library(readr)

source("scripts/R/utils.R")

# --- Config -------------------------------------------------------------------

meta_csv <- "metadata/all_layers_consistent.csv"
target_filename <- "WRI_score.tif"
cogs_dir <- "cogs"
stac_root <- "scratch_output/stac"

collection_id <- "wri_ignitR"
item_datetime <- "2026-06-05T00:00:00Z"

# --- Load metadata ------------------------------------------------------------

if (!file_exists(meta_csv)) stop("Metadata not found: ", meta_csv)

meta <- read_csv(meta_csv, show_col_types = FALSE)
row <- meta[meta$filename == target_filename, ]
if (nrow(row) == 0) stop("No metadata for: ", target_filename)
row <- row[1, ]

cog_path <- path(cogs_dir, row$cog_filename)
if (!file_exists(cog_path)) stop("COG not found: ", cog_path)

item_id <- tools::file_path_sans_ext(row$cog_filename)

# --- Compute spatial (4326) ---------------------------------------------------

spatial <- extent_to_stac_spatial(
  row$extent_xmin, row$extent_xmax, row$extent_ymin, row$extent_ymax
)

# --- Output paths -------------------------------------------------------------

collection_dir <- path(stac_root, "collections", collection_id)
items_dir <- path(collection_dir, "items")
dir_create(items_dir, recurse = TRUE)

catalog_path <- path(stac_root, "catalog.json")
collection_path <- path(collection_dir, "collection.json")
item_path <- path(items_dir, paste0(item_id, ".json"))

# --- Build STAC ---------------------------------------------------------------

catalog <- list(
  stac_version = "1.0.0",
  type = "Catalog",
  id = "wri-catalog",
  description = "WRI raster layers as COGs",
  links = list(
    list(rel = "self", href = "catalog.json", type = "application/json"),
    list(rel = "child", href = path_rel(collection_path, start = stac_root), type = "application/json")
  )
)

collection <- list(
  stac_version = "1.0.0",
  type = "Collection",
  id = collection_id,
  description = "WRI raster layers (COGs)",
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

item <- list(
  stac_version = "1.0.0",
  type = "Feature",
  id = item_id,
  geometry = spatial$geometry,
  bbox = spatial$bbox,
  properties = list(
    datetime = item_datetime,
    "proj:epsg" = as.integer(row$crs_epsg),
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

# --- Write --------------------------------------------------------------------

write_json(catalog, catalog_path, auto_unbox = TRUE, pretty = TRUE)
write_json(collection, collection_path, auto_unbox = TRUE, pretty = TRUE)
write_json(item, item_path, auto_unbox = TRUE, pretty = TRUE)

cat("Wrote:\n")
cat(" ", catalog_path, "\n")
cat(" ", collection_path, "\n")
cat(" ", item_path, "\n")