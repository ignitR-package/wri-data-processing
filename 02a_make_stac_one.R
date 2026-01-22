# =============================================================================
# 02a: Create a minimal STAC Catalog + Collection + Item for ONE COG
# =============================================================================

library(terra)
library(sf)
library(fs)
library(jsonlite)

# --- Config ---
cog_path <- "cogs/livelihoods_domain_score.tif"

stac_root <- "scratch_output/stac" # Directory to STAC
collection_id <- "wri_ignitR" 
item_id <- "livelihoods_domain_score"
item_datetime <- "2026-06-05T00:00:00Z"

# Document COG settings used to generate this file
cog_blocksize <- 512
cog_compress <- "DEFLATE"
cog_overview_resampling <- "AVERAGE"

# --- Output paths ---
catalog_path <- path(stac_root, "catalog.json") 

collection_dir <- path(stac_root, "collections", collection_id) # Directory for items
collection_path <- path(collection_dir, "collection.json")

items_dir <- path(collection_dir, "items") # Directory for item details (geom, bbox, properties, links, assests)
item_path <- path(items_dir, paste0(item_id, ".json")) 

dir_create(items_dir, recurse = TRUE)

# --- Read raster and make bbox/geometry in EPSG:4326 ---
if (!file_exists(cog_path)) stop("COG not found: ", cog_path)

r <- rast(cog_path)
e <- ext(r)

# Make bbox polygon in the raster CRS, then transform to lon/lat
sf_use_s2(FALSE)

bb <- st_bbox(
  c(xmin = xmin(e), ymin = ymin(e), xmax = xmax(e), ymax = ymax(e)),
  crs = st_crs(crs(r))
)

poly_4326 <- st_transform(st_as_sfc(bb), 4326)

# STAC bbox as [xmin, ymin, xmax, ymax] in lon/lat
bb_4326 <- st_bbox(poly_4326)
bbox_4326 <- c(bb_4326["xmin"], bb_4326["ymin"], bb_4326["xmax"], bb_4326["ymax"])
bbox_4326 <- as.numeric(bbox_4326)

# STAC geometry (GeoJSON-style list)
coords <- st_coordinates(st_cast(poly_4326, "POLYGON"))

ring <- vector("list", nrow(coords))
for (i in seq_len(nrow(coords))) {
  lon <- coords[i, "X"]
  lat <- coords[i, "Y"]
  ring[[i]] <- c(lon, lat)
}

geom <- list(
  type = "Polygon",
  coordinates = list(ring)
)

# Optional EPSG code if terra can describe it
proj_epsg <- NA
d <- suppressWarnings(try(crs(r, describe = TRUE), silent = TRUE))
if (!inherits(d, "try-error") && "code" %in% names(d)) proj_epsg <- d$code

# --- Build STAC JSON objects ---

# Required: stac_version, type, id, description, links
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
  license = "proprietary",
  extent = list(
    spatial = list(bbox = list(bbox_4326)),
    temporal = list(interval = list(list(item_datetime, item_datetime)))
  ),
  links = list(
    list(rel = "self", href = path_rel(collection_path, start = stac_root), type = "application/json"),
    list(rel = "root", href = "catalog.json", type = "application/json"),
    list(rel = "parent", href = "catalog.json", type = "application/json"),
    list(rel = "item", href = path_rel(item_path, start = stac_root), type = "application/geo+json") # Child is a stac item
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
    asset_hosting = "local_relative_paths",
    "cog:blocksize" = cog_blocksize,
    "cog:compression" = cog_compress,
    "cog:overview_resampling" = cog_overview_resampling,
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

# --- Write files ---
write_json(catalog, catalog_path, auto_unbox = TRUE, pretty = TRUE)
write_json(collection, collection_path, auto_unbox = TRUE, pretty = TRUE)
write_json(item, item_path, auto_unbox = TRUE, pretty = TRUE)

cat("Wrote:\n")
cat(" ", catalog_path, "\n")
cat(" ", collection_path, "\n")
cat(" ", item_path, "\n")
