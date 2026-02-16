# =============================================================================
# utils.R - Shared helper functions for metadata extraction and STAC creation
#
# Purpose:
#   Central location for reusable functions across the processing pipeline.
#   Includes classification logic, raster metadata extraction, and STAC helpers.
#
# Note:
#   CRS, extent, and resolution are expected to be consistent across the dataset.
#   Any file that violates these expectations should be filtered out upstream.
# =============================================================================

# Suppress GDAL debug messages that clutter output
Sys.setenv("CPL_DEBUG" = "OFF")

library(terra)
library(dplyr)
library(readr)
library(fs)
library(sf)

# =============================================================================
# Numeric comparison
# =============================================================================

#' Compare numeric values with tolerance
#'
#' Used for floating point comparisons of resolution and extent values
#' to avoid false mismatches due to precision differences.
#'
#' @param a First numeric value
#' @param b Second numeric value
#' @param tol Tolerance (default 1e-6)
#' @return TRUE if values are equal within tolerance
near <- function(a, b, tol = 1e-6) {
  isTRUE(all.equal(as.numeric(a), as.numeric(b), tolerance = tol))
}

# =============================================================================
# Filename utilities
# =============================================================================

#' Generate unique COG filename from filepath
#'
#' Handles naming collisions for files in indicators_no_mask/ by adding suffixes.
#'
#' @param filepath Character. Original file path.
#' @return Unique filename for COG output
make_cog_filename <- function(filepath) {
  base <- tools::file_path_sans_ext(basename(filepath))
  
  if (grepl("/indicators_no_mask/", filepath)) {
    return(paste0(base, "_no_mask.tif"))
  }
  
  paste0(base, ".tif")
}

# =============================================================================
# Classification functions
# =============================================================================

#' Classify WRI layer "data_type" from filepath
#'
#' Determines what type of layer a file represents based on its path and name.
#' Used to filter out files we don't want to process and to populate STAC
#' item properties for downstream filtering.
#'
#' @param filepath Character. Path to a GeoTIFF.
#' @return One of: "indicator", "aggregate", "final_score", or "exclude"
#'
#' @examples
#' classify_data_type("data/livelihoods/indicators/foo.tif")
#' # Returns "indicator"
classify_data_type <- function(filepath) {
  
  # Exclude retro/archive directories first
  if (grepl("/retro_|/archive/|/final_checks/", filepath)) {
    return("exclude")
  }
  
  # Indicators live in /indicators/ (includes no_mask)
  if (grepl("/indicators/", filepath)) return("indicator")
  
  # The final combined WRI score
  if (grepl("WRI_score\\.tif$", filepath)) return("final_score")
  
  # Aggregates are domain-level summaries
  if (grepl("_(domain_score|resilience|resistance|status)\\.tif$", filepath)) {
    return("aggregate")
  }
  
  # Everything else should be excluded
  "exclude"
}

#' Extract domain name from filepath
#'
#' Determines which WRI domain a file belongs to (livelihoods, biodiversity, etc.)
#' First checks path structure, then falls back to filename matching.
#'
#' @param filepath Character. Path to a GeoTIFF.
#' @return Domain string (e.g., "livelihoods") or "unknown"
#'
#' @examples
#' extract_domain("data/livelihoods/indicators/foo.tif")
#' # Returns "livelihoods"
extract_domain <- function(filepath) {
  parts <- strsplit(filepath, "/")[[1]]
  
  # For indicators, domain is the parent of /indicators/
  idx <- which(parts == "indicators")
  if (length(idx) > 0 && idx[1] > 1) return(parts[idx[1] - 1])
  
  # Known domain directory names
  domain_dirs <- c(
    "air_quality", "biodiversity", "carbon", "communities",
    "infrastructure", "livelihoods", "natural_habitats",
    "sense_of_place", "sensitivity_analysis", "species", "water"
  )
  
  # Check if any domain appears in path
  
  for (d in domain_dirs) if (any(parts == d)) return(d)
  
  # Fall back to checking filename
  filename <- basename(filepath)
  for (d in domain_dirs) if (grepl(d, filename)) return(d)
  
  "unknown"
}

#' Classify dimension from filename and data_type
#'
#' Determines the specific dimension (resistance, recovery, status, etc.)
#' based on filename patterns. Only applies to indicators and aggregates.
#'
#' @param data_type Character. One of "indicator", "aggregate", "final_score"
#' @param filename Character. Basename of the file
#' @return Dimension string or NA if not applicable
#'
#' @examples
#' classify_dimension("indicator", "foo_resistance_bar.tif")
#' # Returns "resistance"
classify_dimension <- function(data_type, filename) {
  if (data_type == "indicator") {
    if (grepl("_resistance_", filename)) return("resistance")
    if (grepl("_recovery_", filename)) return("recovery")
    if (grepl("_status_", filename)) return("status")
    return(NA_character_)
  }
  
  if (data_type == "aggregate") {
    if (grepl("domain_score", filename)) return("domain_score")
    if (grepl("resilience", filename)) return("resilience")
    if (grepl("resistance", filename)) return("resistance")
    if (grepl("status", filename)) return("status")
    return(NA_character_)
  }
  
  NA_character_
}

# =============================================================================
# Raster metadata extraction
# =============================================================================

#' Extract header metadata from a raster file (no value sampling)
#'
#' Reads only the raster header to get dimensions, CRS, extent, and datatype.
#' This is fast because it doesn't load pixel values into memory.
#'
#' @param filepath Character. Path to a GeoTIFF.
#' @return A named list of metadata fields, including success/error status
get_raster_header <- function(filepath) {
  tryCatch({
    r <- terra::rast(filepath)
    e <- terra::ext(r)
    
    # Extract EPSG code from CRS description
    epsg <- NA_integer_
    crs_desc <- suppressWarnings(try(terra::crs(r, describe = TRUE), silent = TRUE))
    if (!inherits(crs_desc, "try-error") && "code" %in% names(crs_desc)) {
      epsg <- as.integer(crs_desc$code)
    }
    
    list(
      filepath = filepath,
      filename = basename(filepath),
      file_size_mb = round(fs::file_info(filepath)$size / 1024^2, 2),
      nrows = terra::nrow(r),
      ncols = terra::ncol(r),
      nlayers = terra::nlyr(r),
      resolution_x = terra::res(r)[1],
      resolution_y = terra::res(r)[2],
      crs_epsg = epsg,
      extent_xmin = terra::xmin(e),
      extent_xmax = terra::xmax(e),
      extent_ymin = terra::ymin(e),
      extent_ymax = terra::ymax(e),
      datatype = terra::datatype(r)[1],
      success = TRUE,
      error = NA_character_
    )
  }, error = function(e) {
    # Return minimal info on failure so we can track which files had problems
    list(
      filepath = filepath,
      filename = basename(filepath),
      success = FALSE,
      error = as.character(e)
    )
  })
}

# =============================================================================
# STAC helpers
# =============================================================================

#' Convert extent (EPSG:5070) to STAC bbox and geometry (EPSG:4326)
#'
#' STAC requires spatial info in WGS84 (EPSG:4326). This function takes
#' extent coordinates in the native CRS (EPSG:5070) and transforms them.
#'
#' @param xmin,xmax,ymin,ymax Extent coordinates in native CRS
#' @param epsg_native EPSG code of input coordinates (default 5070)
#' @return List with bbox (numeric vector) and geometry (GeoJSON-style list)
extent_to_stac_spatial <- function(xmin, xmax, ymin, ymax, epsg_native = 5070) {
  # Disable s2 for simpler polygon operations
  sf::sf_use_s2(FALSE)
  
  # Build bounding box polygon in native CRS
  bb_native <- st_bbox(
    c(xmin = xmin, ymin = ymin, xmax = xmax, ymax = ymax),
    crs = st_crs(epsg_native)
  )
  
  # Transform to WGS84 for STAC
  poly_4326 <- st_transform(st_as_sfc(bb_native), 4326)
  poly_4326 <- st_cast(poly_4326, "POLYGON")
  
  # Extract bbox as numeric vector [xmin, ymin, xmax, ymax]
  bb <- st_bbox(poly_4326)
  bbox_4326 <- c(unname(bb["xmin"]), unname(bb["ymin"]), 
                 unname(bb["xmax"]), unname(bb["ymax"]))
  
  # Build GeoJSON-style geometry (list of coordinate rings)
  coords <- st_coordinates(poly_4326)
  ring <- lapply(seq_len(nrow(coords)), function(i) c(coords[i, "X"], coords[i, "Y"]))
  
  list(
    bbox = bbox_4326,
    geometry = list(type = "Polygon", coordinates = list(ring))
  )
}

# =============================================================================
# CSV utilities
# =============================================================================

#' Append rows to CSV, creating file if it doesn't exist
#'
#' Used for batch writing during metadata extraction to avoid holding
#' all results in memory.
#'
#' @param rows A list of named lists (each list is one row)
#' @param path Character. Output CSV path
#' @return NULL (writes to disk)
append_rows_csv <- function(rows, path) {
  df <- dplyr::bind_rows(rows)
  
  if (!fs::file_exists(path)) {
    readr::write_csv(df, path)
  } else {
    readr::write_csv(df, path, append = TRUE)
  }
  
  invisible(NULL)
}