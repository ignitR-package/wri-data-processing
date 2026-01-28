# =============================================================================
# 02a: Create a minimal STAC Catalog + Collection + Item for ONE COG (metadata-driven)
#
# Goal:
#   Build a tiny STAC that points to ONE COG, without re-reading raster metadata.
#   We trust the metadata CSV created upstream (00a/00b).
#
# Inputs:
#   - config/all_layers_consistent.csv   (metadata for consistent rasters)
#   - a COG file on disk (path built from metadata)
#
# Outputs:
#   - scratch_output/stac/catalog.json
#   - scratch_output/stac/collections/<collection_id>/collection.json
#   - scratch_output/stac/collections/<collection_id>/items/<item_id>.json
#
# Notes:
#   - STAC geometry and bbox must be in EPSG:4326 (lon/lat).
#   - The metadata CSV extent is in EPSG:5070 (Conus Albers), so we reproject
#     the extent polygon using sf (no terra raster read needed).
#   - COGs are currently created using terra::writeRaster(filetype = "COG")
#     with default settings.
# =============================================================================

library(sf)
library(fs)
library(jsonlite)
library(readr)

# --- Config ---------------------------------------------------------------

meta_csv <- "config/all_layers_consistent.csv"

# Pick ONE layer to publish as an Item.
# Easiest: match by the original filename in metadata (not the COG name).
# Example from your CSV: "WRI_score.tif"
target_filename <- "WRI_score.tif"

# Where the COGs live (created by 01b)
cogs_dir <- "cogs"

# Where to write this prototype STAC
stac_root <- "scratch_output/stac"

catalog_id <- "wri-catalog"
collection_id <- "wri_ignitR"

# A single datetime is fine for now (you can revise later)
item_datetime <- "2026-06-05T00:00:00Z"

# --- Load metadata and select one row ------------------------------------

if (!file_exists(meta_csv)) stop("Metadata CSV not found: ", meta_csv)

meta <- read_csv(meta_csv, show_col_types = FALSE)

if (!("filename" %in% names(meta))) stop("metadata CSV missing 'filename' column")
if (!("filepath" %in% names(meta))) stop("metadata CSV missing 'filepath' column")

row <- meta[meta$filename == target_filename, ]
if (nrow(row) == 0) stop("No metadata row found for filename: ", target_filename)

# If there are duplicates, just take the first (prototype behavior)
row <- row[1, ]

# --- Build COG path and basic IDs ----------------------------------------

# Our COG output uses basename(original_filepath) as filename in cogs/
# (this matches 01b).
cog_path <- path(cogs_dir, row$filename)

if (!file_exists(cog_path)) stop("COG not found: ", cog_path)

item_id <- tools::file_path_sans_ext(row$filename)

# --- Build bbox + geometry in EPSG:4326 ----------------------------------

# The metadata extent is in EPSG:5070 (validated upstream).
# We convert extent -> polygon in 5070, then transform to 4326 for STAC.
sf_use_s2(FALSE)

bb_5070 <- st_bbox(
  c(
    xmin = row$extent_xmin,
    ymin = row$extent_ymin,
    xmax = row$extent_xmax,
    ymax = row$extent_ymax
  ),
  crs = st_crs(5070)
)

poly_4326 <- st_transform(st_as_sfc(bb_5070), 4326)

bb_4326 <- st_bbox(poly_4326)
bbox_4326 <- as.numeric(c(bb_4326["xmin"], bb_4326["ymin"], bb_4326["xmax"], bb_4326["ymax"]))

# GeoJSON-style polygon coordinates
coords <- st_coordinates(st_cast(poly_4326, "POLYGON"))

ring <- vector("list", nrow(coords))
for (i in seq_len(nrow(coords))) {
  ring[[i]] <- c(coords[i, "X"], coords[i, "Y"])
}

geom <- list(type = "Polygon", coordinates = list(ring))

# --- Output paths ---------------------------------------------------------

catalog_path <- path(stac_root, "catalog.json")

collection_dir <- path(stac_root, "collections", collection_id)
collection_path <- path(collection_dir, "collection.json")

items_dir <- path(collection_dir, "items")
item_path <- path(items_dir, paste0(item_id, ".json"))

dir_create(items_dir, recurse = TRUE)

# --- Build STAC JSON objects ---------------------------------------------
# Structure:
#   Catalog (root) links to Collection (child)
#   Collection links to Item(s)
#   Item contains:
#     - geometry/bbox
#     - properties (time + useful metadata)
#     - assets (the COG href)

catalog <- list(
  stac_version = "1.0.0",
  type = "Catalog",
  id = catalog_id,
  description = "WRI raster layers as Cloud Optimized GeoTIFFs (COGs)",
  links = list(
    list(rel = "self",  href = "catalog.json", type = "application/json"),
    list(rel = "child", href = path_rel(collection_path, start = stac_root), type = "application/json")
  )
)

collection <- list(
  stac_version = "1.0.0",
  type = "Collection",
  id = collection_id,
  description = "WRI raster layers (COGs) in one collection",
  license = "proprietary",
  extent = list(
    spatial  = list(bbox = list(bbox_4326)),
    temporal = list(interval = list(list(item_datetime, item_datetime)))
  ),
  links = list(
    list(rel = "self",   href = path_rel(collection_path, start = stac_root), type = "application/json"),
    list(rel = "root",   href = "catalog.json", type = "application/json"),
    list(rel = "parent", href = "catalog.json", type = "application/json"),
    list(rel = "item",   href = path_rel(item_path, start = stac_root), type = "application/geo+json")
  )
)

item <- list(
  stac_version = "1.0.0",
  type = "Feature",
  id = item_id,
  geometry = geom,
  bbox = bbox_4326,
  properties = list(
    datetime = item_datetime,
    
    # Useful metadata from the CSV (no raster read needed)
    "proj:epsg" = as.integer(row$crs),
    "proj:shape" = c(as.integer(row$nrows), as.integer(row$ncols)),
    resolution_m = c(as.numeric(row$resolution_x), as.numeric(row$resolution_y)),
    source_filepath = row$filepath,
    
    # Optional: simple summaries (already computed in 00b)
    value_min = as.numeric(row$value_min),
    value_max = as.numeric(row$value_max),
    value_mean = as.numeric(row$value_mean),
    na_percent = as.numeric(row$na_percent),
    
    # Processing notes
    processing_assumptions = "CRS/extent/resolution validated upstream in 00a/00b",
    cog_specs = "terra::writeRaster(filetype = 'COG') defaults"
  ),
  assets = list(
    data = list(
      href  = path_rel(cog_path, start = stac_root),
      type  = "image/tiff; application=geotiff; profile=cloud-optimized",
      roles = list("data"),
      title = "COG"
    )
  ),
  links = list(
    list(rel = "self",       href = path_rel(item_path, start = stac_root), type = "application/geo+json"),
    list(rel = "root",       href = "catalog.json", type = "application/json"),
    list(rel = "parent",     href = path_rel(collection_path, start = stac_root), type = "application/json"),
    list(rel = "collection", href = path_rel(collection_path, start = stac_root), type = "application/json")
  )
)

# --- Write files ----------------------------------------------------------

write_json(catalog,    catalog_path,    auto_unbox = TRUE, pretty = TRUE)
write_json(collection, collection_path, auto_unbox = TRUE, pretty = TRUE)
write_json(item,       item_path,       auto_unbox = TRUE, pretty = TRUE)

cat("Wrote:\n")
cat(" ", catalog_path, "\n")
cat(" ", collection_path, "\n")
cat(" ", item_path, "\n")
