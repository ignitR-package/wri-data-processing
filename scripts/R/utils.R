# =============================================================================
# File: R/utils.R
# Purpose: Shared helper functions for WRI data processing pipeline
# Author: ignitR Team (Em, Ixel, Kaiju, Hylaea)
# Created: January 2025
#
# Description:
#   This file contains reusable functions shared across the metadata extraction,
#   COG conversion, and STAC catalog creation scripts. Centralizing these
#   functions ensures consistency and makes maintenance easier.
#
# Usage:
#   source("scripts/R/utils.R")
# =============================================================================


# -----------------------------------------------------------------------------
# Statistical Helpers
# -----------------------------------------------------------------------------

#' Calculate the mode (most frequent value) of a vector
#'
#' @description
#' Returns the most commonly occurring value in a vector. Used for determining
#' the "expected" resolution, CRS, and extent values across all raster layers.
#'
#' @param x A vector of values (character, numeric, etc.)
#'
#' @return The most frequent value in `x`. If there are ties, returns the first
#'   one encountered. Returns NULL if `x` is empty after removing NAs.
#'
#' @examples
#' get_mode(c("a", "b", "a", "c", "a"))
#' # Returns: "a"
#'
#' get_mode(c(100, 100, 200, 100, 300))
#' # Returns: "100" (as character due to table/names)
get_mode <- function(x) {
  # Remove missing values
  
  x <- x[!is.na(x)]
  
  if (length(x) == 0) {
    return(NULL)
  }
  
  # Count how many times each value appears
  counts <- table(x)
  
  # Find most frequent
  mode_value <- names(counts)[which.max(counts)]
  
  return(mode_value)
}


# -----------------------------------------------------------------------------
# Domain Classification
# -----------------------------------------------------------------------------
#' Extract domain name from a WRI file path
#'
#' @description
#' Parses the file path to identify which WRI domain the layer belongs to.
#' Uses three strategies in order:
#' 1. Looks for known domain directories before "/indicators/" in the path
#' 2. Searches path components for known domain names
#' 3. Falls back to checking the filename itself
#'
#' @param filepath Character string. Full or relative path to a GeoTIFF file.
#'
#' @return Character string with the domain name (e.g., "livelihoods",
#'   "infrastructure"). Returns "unknown" if no domain can be identified.
#'
#' @details
#' The WRI dataset is organized into domains:
#' - air_quality
#' - biodiversity
#' - carbon
#' - communities
#' - infrastructure
#' - livelihoods
#' - natural_habitats
#' - sense_of_place
#' - sensitivity_analysis
#' - species
#' - water
#'
#' @examples
#' extract_domain("data/livelihoods/indicators/some_layer.tif")
#' # Returns: "livelihoods"
#'
#' extract_domain("data/infrastructure_domain_score.tif
#' # Returns: "infrastructure"
extract_domain <- function(filepath) {
  path_parts <- strsplit(filepath, "/")[[1]]
  
  # Known domain directories
  domain_dirs <- c(
    "air_quality", "biodiversity", "carbon", "communities",
    "infrastructure", "livelihoods", "natural_habitats",
    "sense_of_place", "sensitivity_analysis", "species", "water"
  )
  
  # Strategy 1: Find directory before "indicators"
  indicators_idx <- which(path_parts == "indicators")
  if (length(indicators_idx) > 0) {
    domain_idx <- indicators_idx[1] - 1
    if (domain_idx > 0) {
      return(path_parts[domain_idx])
    }
  }
  
  # Strategy 2: Check all path parts for known domains
  for (domain in domain_dirs) {
    if (any(grepl(domain, path_parts))) {
      return(domain)
    }
  }
  
  # Strategy 3: Check filename
  filename <- basename(filepath)
  for (domain in domain_dirs) {
    if (grepl(domain, filename)) {
      return(domain)
    }
  }
  
  # No match found
  return("unknown")
}


# -----------------------------------------------------------------------------
# Raster Metadata Extraction
# -----------------------------------------------------------------------------

#' Extract metadata from a single raster file
#'
#' @description
#' Reads a GeoTIFF file and extracts comprehensive metadata including
#' dimensions, resolution, CRS, extent, and basic statistics. Wrapped in
#' error handling to gracefully handle corrupt or unreadable files.
#'
#' @param filepath Character string. Path to a GeoTIFF file.
#'
#' @return A named list containing:
#'
#'   **Identification:**
#'   - `filepath`: Original file path
#'   - `filename`: Base filename
#'
#'   **File characteristics:**
#'   - `file_size_mb`: File size in megabytes
#'   - `datatype`: Raster data type (e.g., "FLT4S", "INT2S")
#'
#'   **Dimensions:**
#'   - `ncols`, `nrows`, `ncells`, `nlayers`: Raster dimensions
#'
#'   **Spatial properties:**
#'   - `resolution_x`, `resolution_y`: Cell size
#'   - `crs`: EPSG code (if available)
#'   - `crs_full`: Full CRS WKT string
#'   - `extent_xmin`, `extent_xmax`, `extent_ymin`, `extent_ymax`: Bounding box
#'
#'   **Data statistics:**
#'   - `value_min`, `value_max`, `value_mean`: Basic statistics
#'   - `na_cells`, `na_percent`: Missing data info
#'
#'   **Status:**
#'   - `success`: TRUE if read succeeded, FALSE otherwise
#'   - `error`: Error message if read failed, NA otherwise
#'
#' @note
#' Computing global statistics (min, max, mean) requires reading the entire
#' raster into memory and can be slow for large files (~2.5 GB each).
#'
#' @examples
#' info <- get_raster_info("data/livelihoods/livelihoods_domain_score.tif")
#' if (info$success) {
#'   cat("File size:", info$file_size_mb, "MB\n")
#'   cat("Resolution:", info$resolution_x, "x", info$resolution_y, "\n")
#' }
get_raster_info <- function(filepath) {
  tryCatch({
    r <- terra::rast(filepath)
    
    # Global stats (slow but necessary for QC)
    vmin <- terra::global(r, "min", na.rm = TRUE)[1, 1]
    vmax <- terra::global(r, "max", na.rm = TRUE)[1, 1]
    vmean <- terra::global(r, "mean", na.rm = TRUE)[1, 1]
    
    info <- list(
      filepath = filepath,
      filename = basename(filepath),
      file_size_mb = round(fs::file_size(filepath) / (2^20), 2),
      ncols = ncol(r),
      nrows = nrow(r),
      ncells = ncell(r),
      nlayers = nlyr(r),
      resolution_x = terra::res(r)[1],
      resolution_y = terra::res(r)[2],
      crs = terra::crs(r, describe = TRUE)$code,
      crs_full = as.character(terra::crs(r)),
      extent_xmin = terra::ext(r)[1],
      extent_xmax = terra::ext(r)[2],
      extent_ymin = terra::ext(r)[3],
      extent_ymax = terra::ext(r)[4],
      value_min = vmin,
      value_max = vmax,
      value_mean = vmean,
      na_cells = terra::freq(r, value = NA)$count[1],
      na_percent = round((terra::freq(r, value = NA)$count[1] / ncell(r)) * 100, 2),
      datatype = terra::datatype(r)[1],
      success = TRUE,
      error = NA
    )
    
    return(info)
    
  }, error = function(e) {
    return(list(
      filepath = filepath,
      filename = basename(filepath),
      success = FALSE,
      error = as.character(e)
    ))
  })
}


# -----------------------------------------------------------------------------
# COG Conversion Helpers
# -----------------------------------------------------------------------------

#' Choose resampling method for COG overview generation
#'
#' @description
#' Determines the appropriate resampling algorithm for building COG overviews
#' based on the layer type and data type. Categorical data (like status layers)
#' uses NEAREST to preserve discrete values, while continuous data uses AVERAGE.
#'
#' @param layer_type Character. The WRI layer type: "status", "resistance",
#'   "recovery", "resilience", "domain_score", or NA.
#' @param datatype_str Character. The raster data type from terra::datatype(),
#'   e.g., "FLT4S" (float), "INT2S" (integer).
#'
#' @return Character string: "NEAREST" for categorical data, "AVERAGE" for
#'   continuous data.
#'
#' @details
#' Decision rules:
#' 1. Status layers are categorical → NEAREST
#' 2. Integer rasters are likely categorical → NEAREST
#' 3. Everything else (floats, scores) → AVERAGE
#'
#' @examples
#' choose_resampling("status", "INT2S")
#' # Returns: "NEAREST"
#'
#' choose_resampling("domain_score", "FLT4S")
#' # Returns: "AVERAGE"
choose_resampling <- function(layer_type, datatype_str) {
  
  # Rule 1: status layers are categorical
  if (!is.na(layer_type) && layer_type == "status") {
    return("NEAREST")
  }
  
  # Rule 2: integer rasters are probably categorical or discrete
  if (!is.na(datatype_str)) {
    if (grepl("INT|UINT|SINT", datatype_str, ignore.case = TRUE)) {
      return("NEAREST")
    }
  }
  
  # Default: treat as continuous
  return("AVERAGE")
}


# -----------------------------------------------------------------------------
# STAC Helpers
# -----------------------------------------------------------------------------

#' Generate STAC item ID from file path
#'
#' @description
#' Creates a standardized item ID by extracting the filename without extension.
#'
#' @param filepath Character string. Path to a COG file.
#'
#' @return Character string suitable for use as a STAC item ID.
#'
#' @examples
#' make_item_id("cogs/aggregate/livelihoods/livelihoods_domain_score.tif")
#' # Returns: "livelihoods_domain_score"
make_item_id <- function(filepath) {
  tools::file_path_sans_ext(basename(filepath))
}


#' Extract spatial metadata for STAC item
#'
#' @description
#' Reads a COG and extracts the bounding box and geometry in EPSG:4326
#' (WGS84 lat/lon) as required by the STAC specification.
#'
#' @param cog_path Character string. Path to a Cloud-Optimized GeoTIFF.
#'
#' @return A named list containing:
#'   - `geometry`: GeoJSON Polygon geometry object
#'   - `bbox`: Numeric vector [xmin, ymin, xmax, ymax] in EPSG:4326
#'   - `proj_epsg`: EPSG code of the native projection (or NA)
#'
#' @details
#' The function:
#' 1. Reads the raster extent in its native CRS
#' 2. Creates a bounding box polygon
#' 3. Transforms to EPSG:4326 for STAC compliance
#' 4. Extracts coordinates as a GeoJSON-compatible structure
#'
#' @note
#' Temporarily disables s2 spherical geometry to avoid edge cases with
#' bounding box transformations.
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
  
  # Extent as plain numbers
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


#' Compute union of multiple bounding boxes
#'
#' @description
#' Combines multiple STAC-format bounding boxes into a single bbox that
#' encompasses all of them. Used to compute collection-level extent.
#'
#' @param bbox_list List of numeric vectors, each [xmin, ymin, xmax, ymax].
#'
#' @return Numeric vector [xmin, ymin, xmax, ymax] representing the union.
#'
#' @examples
#' bbox_union(list(
#'   c(-120, 30, -110, 40),
#'   c(-115, 35, -105, 45)
#' ))
#' # Returns: c(-120, 30, -105, 45)
bbox_union <- function(bbox_list) {
  xs_min <- sapply(bbox_list, function(b) b[1])
  ys_min <- sapply(bbox_list, function(b) b[2])
  xs_max <- sapply(bbox_list, function(b) b[3])
  ys_max <- sapply(bbox_list, function(b) b[4])
  
  c(min(xs_min), min(ys_min), max(xs_max), max(ys_max))
}