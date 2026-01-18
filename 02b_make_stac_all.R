# Purpose: 02b Create a STAC Catalog + ONE Collection + MANY Items for ALL COGs
#
# Reads:
#   outputs/validation_reports/cog_conversion_log.csv
# Writes:
#   stac/catalog.json
#   stac/collections/<collection_id>/collection.json
#   stac/collections/<collection_id>/items/<item_id>.json

library(readr)
library(dplyr)
library(terra)
library(sf)
library(fs)
library(jsonlite)

# Config ------------------------------------------------------------------

log_path <- "outputs/validation_reports/cog_conversion_log.csv"

stac_root <- "stac"
collection_id <- "wri_ignitR"

# Required STAC field. Use a fixed "publication" datetime.
item_datetime <- "2026-06-05T00:00:00Z"

# Document COG generation choices (assumed consistent across batch)
cog_blocksize <- 512
cog_compress <- "DEFLATE"

# Output paths ------------------------------------------------------------

catalog_path <- path(stac_root, "catalog.json")
collection_dir <- path(stac_root, "collections", collection_id)
collection_path <- path(collection_dir, "collection.json")
items_dir <- path(collection_dir, "items")

dir_create(items_dir, recurse = TRUE)

# Helpers -----------------------------------------------------------------

# Make an item id from a path (basename without extension)
make_item_id <- function(filepath) {
  tools::file_path_sans_ext(basename(filepath))
}

# Extract bbox + geometry from a raster in EPSG:4326, plus proj epsg if available
get_item_spatial <- function(cog_path) {
  
  r <- terra::rast(cog_path)
  
  # CRS check
  r_crs <- terra::crs(r)
  if (is.na(r_crs) || nchar(r_crs) == 0) {
    stop(paste("Raster CRS missing for:", cog_path))
  }
  
  # EPSG code if available
  proj_epsg <- NA
  crs_desc <- try(terra::crs(r, describe = TRUE), silent = TRUE)
  if (!inherits(crs_desc, "try-error")) {
    if ("code" %in% names(crs_desc)) proj_epsg <- crs_desc$code
  }
  
  # Extent as plain numbers (terra ext is S4)
  e <- terra::ext(r)
  
  xmin <- terra::xmin(e)
  xmax <- terra::xmax(e)
  ymin <- terra::ymin(e)
  ymax <- terra::ymax(e)
  
  vals <- c(xmin, ymin, xmax, ymax)
  if (any(is.na(vals)) || any(!is.finite(vals))) {
    stop(paste("Raster extent has NA/non-finite values for:", cog_path))
  }
  
  # Build bbox polygon in native CRS
  sf::sf_use_s2(FALSE)
  
  bb_native <- sf::st_bbox(
    c(xmin = xmin, ymin = ymin, xmax = xmax, ymax = ymax),
    crs = sf::st_crs(r_crs)
  )
  
  poly_native <- sf::st_as_sfc(bb_native)
  
  # Transform to lon/lat for STAC
  poly_4326 <- sf::st_transform(poly_native, 4326)
  
  # GeoJSON geometry (Polygon)
  poly_4326 <- sf::st_cast(poly_4326, "POLYGON")
  coords <- sf::st_coordinates(poly_4326)
  ring <- lapply(seq_len(nrow(coords)), function(i) c(coords[i, "X"], coords[i, "Y"]))
  
  geom <- list(
    type = "Polygon",
    coordinates = list(ring)
  )
  
  # STAC bbox in EPSG:4326
  bb <- sf::st_bbox(poly_4326)
  bbox_4326 <- c(unname(bb["xmin"]), unname(bb["ymin"]), unname(bb["xmax"]), unname(bb["ymax"]))
  
  list(
    geometry = geom,
    bbox = bbox_4326,
    proj_epsg = proj_epsg
  )
}

# Union of many bboxes: each bbox is [xmin, ymin, xmax, ymax]
bbox_union <- function(bbox_list) {
  xs_min <- sapply(bbox_list, function(b) b[1])
  ys_min <- sapply(bbox_list, function(b) b[2])
  xs_max <- sapply(bbox_list, function(b) b[3])
  ys_max <- sapply(bbox_list, function(b) b[4])
  
  c(min(xs_min), min(ys_min), max(xs_max), max(ys_max))
}

# Main --------------------------------------------------------------------

# Read conversion log
if (!file_exists(log_path)) {
  stop(paste("Missing log file:", log_path))
}

log_df <- read_csv(log_path, show_col_types = FALSE)

# Keep outputs that should exist
log_df <- log_df %>%
  filter(status %in% c("converted", "skipped_exists"))

if (nrow(log_df) == 0) {
  stop("No usable rows in conversion log (expected converted or skipped_exists).")
}

# Build items
all_bboxes <- list()
items_written <- 0

for (i in seq_len(nrow(log_df))) {
  
  cog_out <- log_df$output[i]
  
  if (!file_exists(cog_out)) {
    cat("Missing COG, skipping:", cog_out, "\n")
    next
  }
  
  item_id <- make_item_id(cog_out)
  item_path <- path(items_dir, paste0(item_id, ".json"))
  
  # Skip writing if item already exists (rerun safe)
  if (file_exists(item_path)) {
    cat(sprintf("[%d/%d] STAC item exists, skipping: %s\n", i, nrow(log_df), item_id))
    next
  }
  
  cat(sprintf("[%d/%d] Writing item: %s\n", i, nrow(log_df), item_id))
  
  # Spatial metadata
  spatial <- get_item_spatial(cog_out)
  all_bboxes[[length(all_bboxes) + 1]] <- spatial$bbox
  
  # Pull optional fields from the log (only if present)
  data_type <- if ("data_type" %in% names(log_df)) log_df$data_type[i] else NA
  domain <- if ("domain" %in% names(log_df)) log_df$domain[i] else NA
  layer_type <- if ("layer_type" %in% names(log_df)) log_df$layer_type[i] else NA
  overview_resampling <- if ("resampling" %in% names(log_df)) log_df$resampling[i] else NA
  
  # Build item JSON
  item <- list(
    stac_version = "1.0.0",
    type = "Feature",
    id = item_id,
    geometry = spatial$geometry,
    bbox = spatial$bbox,
    properties = list(
      datetime = item_datetime,
      
      # Optional categorization fields
      data_type = data_type,
      domain = domain,
      layer_type = layer_type,
      
      # Document conversion choices
      "cog:blocksize" = cog_blocksize,
      "cog:compression" = cog_compress,
      "cog:overview_resampling" = overview_resampling,
      
      # Projection info
      "proj:epsg" = spatial$proj_epsg
    ),
    assets = list(
      data = list(
        # Local relative href, replace later with KNB URLs
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
  
  # Write item file
  write_json(item, item_path, auto_unbox = TRUE, pretty = TRUE)
  
  items_written <- items_written + 1
  
  # Save progress every 25 items (helps if interrupted)
  if (items_written %% 25 == 0) {
    cat("Progress:", items_written, "items written\n")
  }
}

if (length(all_bboxes) == 0) {
  stop("No bboxes collected. Did any items get written?")
}

# Build collection bbox (union across all items that were processed in this run)
collection_bbox <- bbox_union(all_bboxes)

# Build catalog + collection
catalog <- list(
  stac_version = "1.0.0",
  type = "Catalog",
  id = "wri-catalog",
  description = "WRI raster layers as Cloud Optimized GeoTIFFs (COGs)",
  links = list(
    list(rel = "self", href = "catalog.json", type = "application/json"),
    list(rel = "child", href = path_rel(collection_path, start = stac_root), type = "application/json")
  )
)

collection <- list(
  stac_version = "1.0.0",
  type = "Collection",
  id = collection_id,
  description = "WRI raster layers (COGs) in one collection",
  license = "proprietary",  # change if you have a real license string
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

# Write catalog + collection
write_json(catalog, catalog_path, auto_unbox = TRUE, pretty = TRUE)
write_json(collection, collection_path, auto_unbox = TRUE, pretty = TRUE)

cat("\nDone.\n")
cat("Wrote catalog:    ", catalog_path, "\n")
cat("Wrote collection: ", collection_path, "\n")
cat("Wrote items in:   ", items_dir, "\n")
cat("Items written:    ", items_written, "\n")
