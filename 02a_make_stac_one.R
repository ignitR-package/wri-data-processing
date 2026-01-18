# Purpose: 02a Create a minimal STAC Catalog + Collection + Item for ONE COG

library(terra)
library(sf)
library(fs)
library(jsonlite)

# Config ------------------------------------------------------------------

cog_path <- "cogs/livelihoods_domain_score.tif"

stac_root <- "stac"
collection_id <- "wri_ignitR"
item_id <- "livelihoods_domain_score"

# Define STAC Item datetime
item_datetime <- "2026-06-05T00:00:00Z"

# Document COG generation choices
cog_blocksize <- 512
cog_compress <- "DEFLATE"
cog_overview_resampling <- "AVERAGE"  # for this layer

# Output paths ------------------------------------------------------------

catalog_path <- path(stac_root, "catalog.json")
collection_dir <- path(stac_root, "collections", collection_id)
collection_path <- path(collection_dir, "collection.json")
items_dir <- path(collection_dir, "items")
item_path <- path(items_dir, paste0(item_id, ".json"))

dir_create(items_dir, recurse = TRUE)

# Read spatial info from the COG ------------------------------------------

if (!file_exists(cog_path)) {
  stop(paste("COG not found:", cog_path))
}

# Read raster
r <- terra::rast(cog_path)

# CRS check
r_crs <- terra::crs(r)
if (is.na(r_crs) || nchar(r_crs) == 0) {
  stop("Raster CRS is missing. Cannot transform extent to EPSG:4326.")
}

# Try to get EPSG code (optional, but nice to include)
proj_epsg <- NA
crs_desc <- try(terra::crs(r, describe = TRUE), silent = TRUE)
if (!inherits(crs_desc, "try-error")) {
  if ("code" %in% names(crs_desc)) {
    proj_epsg <- crs_desc$code
  }
}

# Get extent as plain numbers (important)
e <- terra::ext(r)

xmin <- terra::xmin(e)
xmax <- terra::xmax(e)
ymin <- terra::ymin(e)
ymax <- terra::ymax(e)

vals <- c(xmin, ymin, xmax, ymax)
if (any(is.na(vals)) || any(!is.finite(vals))) {
  stop(paste("Raster extent has NA or non-finite values:", paste(vals, collapse = ", ")))
}

# Build bbox polygon in native CRS
sf::sf_use_s2(FALSE)

bb_native <- sf::st_bbox(
  c(xmin = xmin, ymin = ymin, xmax = xmax, ymax = ymax),
  crs = sf::st_crs(r_crs)
)

poly_native <- sf::st_as_sfc(bb_native)

# Transform to EPSG:4326 (lon/lat) for STAC
poly_4326 <- sf::st_transform(poly_native, 4326)

# Geometry and bbox for STAC ---------------------------------------------

# Convert polygon to GeoJSON geometry (simple, no extra packages)
poly_4326 <- sf::st_cast(poly_4326, "POLYGON")
coords <- sf::st_coordinates(poly_4326)

# Build ring: list of [lon, lat] coordinate pairs
ring <- lapply(seq_len(nrow(coords)), function(i) c(coords[i, "X"], coords[i, "Y"]))

# GeoJSON Polygon geometry object
geom <- list(
  type = "Polygon",
  coordinates = list(ring)
)

# Bbox in EPSG:4326
bb <- sf::st_bbox(poly_4326)
bbox_4326 <- c(unname(bb["xmin"]), unname(bb["ymin"]), unname(bb["xmax"]), unname(bb["ymax"]))

# Build STAC objects ------------------------------------------------------

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

# Collection extent (for 02a: just this one item)
collection <- list(
  stac_version = "1.0.0",
  type = "Collection",
  id = collection_id,
  description = "WRI raster layers (COGs) in one collection",
  license = "proprietary",  # change if you have a real license string
  extent = list(
    spatial = list(bbox = list(bbox_4326)),
    temporal = list(interval = list(list(item_datetime, item_datetime)))
  ),
  links = list(
    list(rel = "self", href = path_rel(collection_path, start = stac_root), type = "application/json"),
    list(rel = "root", href = "catalog.json", type = "application/json"),
    list(rel = "parent", href = "catalog.json", type = "application/json"),
    list(rel = "item", href = path_rel(item_path, start = stac_root), type = "application/geo+json")
  )
)

# Item (href relative for local use, update with KNB URLs later)
item <- list(
  stac_version = "1.0.0",
  type = "Feature",
  id = item_id,
  geometry = geom,
  bbox = bbox_4326,
  properties = list(
    datetime = item_datetime,
    
    # Document that asset hosting is not finalized yet
    asset_hosting = "local_relative_paths",
    
    # Document conversion choices
    "cog:blocksize" = cog_blocksize,
    "cog:compression" = cog_compress,
    "cog:overview_resampling" = cog_overview_resampling,
    
    # Projection information
    "proj:epsg" = proj_epsg
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

# Write JSON files --------------------------------------------------------

write_json(catalog, catalog_path, auto_unbox = TRUE, pretty = TRUE)
write_json(collection, collection_path, auto_unbox = TRUE, pretty = TRUE)
write_json(item, item_path, auto_unbox = TRUE, pretty = TRUE)

cat("Wrote:\n")
cat("  ", catalog_path, "\n")
cat("  ", collection_path, "\n")
cat("  ", item_path, "\n")
