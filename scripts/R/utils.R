# =============================================================================
# File: scripts/R/utils.R
# Purpose: Shared helper functions for metadata extraction and classification
#
# Note:
#   CRS, extent, and resolution are expected to be consistent across the dataset.
#   Any file that violates these expectations should be filtered out upstream and
#   will not be processed further here.
# =============================================================================

library(terra)
library(dplyr)
library(readr)
library(fs)

#' Classify WRI layer "data_type" from a filepath
#'
#' @param filepath Character. Path to a GeoTIFF.
#' @return One of: "indicator", "aggregate", "final_score", or "exclude".
#' @examples
#' classify_data_type("data/livelihoods/indicators/foo.tif")
classify_data_type <- function(filepath) {
  if (grepl("/indicators/", filepath)) return("indicator")
  if (grepl("WRI_score\\.tif$", filepath)) return("final_score")
  
  if (grepl("_(domain_score|resilience|resistance|status)\\.tif$", filepath) &&
      !grepl("/indicators/|/final_checks/|/archive/|/indicators_no_mask/", filepath)) {
    return("aggregate")
  }
  
  "exclude"
}

#' Extract domain name from filepath
#'
#' @param filepath Character. Path to a GeoTIFF.
#' @return Domain string (for example "livelihoods") or "unknown".
#' @examples
#' extract_domain("data/livelihoods/indicators/foo.tif")
extract_domain <- function(filepath) {
  parts <- strsplit(filepath, "/")[[1]]
  
  idx <- which(parts == "indicators")
  if (length(idx) > 0 && idx[1] > 1) return(parts[idx[1] - 1])
  
  domain_dirs <- c(
    "air_quality", "biodiversity", "carbon", "communities",
    "infrastructure", "livelihoods", "natural_habitats",
    "sense_of_place", "sensitivity_analysis", "species", "water"
  )
  
  for (d in domain_dirs) if (any(parts == d)) return(d)
  
  filename <- basename(filepath)
  for (d in domain_dirs) if (grepl(d, filename)) return(d)
  
  "unknown"
}

#' Classify layer type from filename and data_type
#'
#' @param data_type Character. One of "indicator", "aggregate", "final_score".
#' @param filename Character. Basename of the file.
#' @return A layer type string or NA.
#' @examples
#' classify_layer_type("indicator", "foo_resistance_bar.tif")
classify_layer_type <- function(data_type, filename) {
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

#' Compute sample-based raster value summaries
#'
#' @param r A SpatRaster with one layer.
#' @param n Integer. Number of cells to sample.
#' @return A named list with value_min, value_max, value_mean, na_percent.
summarize_sample <- function(r, n) {
  set.seed(1)
  x <- terra::spatSample(
    r,
    size = n,
    method = "random",
    na.rm = FALSE,
    as.df = TRUE
  )[, 1]
  x <- as.numeric(x)
  
  list(
    value_min = suppressWarnings(min(x, na.rm = TRUE)),
    value_max = suppressWarnings(max(x, na.rm = TRUE)),
    value_mean = suppressWarnings(mean(x, na.rm = TRUE)),
    na_percent = round(mean(is.na(x)) * 100, 3)
  )
}

#' Extract key metadata for one raster file
#'
#' Note:
#'   This function does not attempt to harmonize or compare CRS/extent/resolution.
#'
#' @param filepath Character. Path to a GeoTIFF.
#' @param sample_size Integer. Sample size for value summaries.
#' @return A named list of metadata fields. Includes success/error fields.
get_raster_info <- function(filepath, sample_size = 200000) {
  tryCatch({
    r <- terra::rast(filepath)
    e <- terra::ext(r)
    
    # EPSG code if available
    epsg <- NA
    crs_desc <- suppressWarnings(try(terra::crs(r, describe = TRUE), silent = TRUE))
    if (!inherits(crs_desc, "try-error") && "code" %in% names(crs_desc)) epsg <- crs_desc$code
    
    stats <- summarize_sample(r, sample_size)
    
    list(
      filepath = filepath,
      filename = basename(filepath),
      file_size_mb = round(fs::file_info(filepath)$size / 1024^2, 2),
      
      ncols = terra::ncol(r),
      nrows = terra::nrow(r),
      ncells = terra::ncell(r),
      nlayers = terra::nlyr(r),
      
      resolution_x = terra::res(r)[1],
      resolution_y = terra::res(r)[2],
      
      crs = epsg,
      crs_full = as.character(terra::crs(r)),
      
      extent_xmin = terra::xmin(e),
      extent_xmax = terra::xmax(e),
      extent_ymin = terra::ymin(e),
      extent_ymax = terra::ymax(e),
      
      datatype = terra::datatype(r)[1],
      
      value_min = stats$value_min,
      value_max = stats$value_max,
      value_mean = stats$value_mean,
      na_percent = stats$na_percent,
      
      success = TRUE,
      error = NA_character_
    )
  }, error = function(e) {
    list(
      filepath = filepath,
      filename = basename(filepath),
      success = FALSE,
      error = as.character(e)
    )
  })
}

#' Append rows to a CSV file, creating it if it does not exist
#'
#' @param rows A list of named lists (each list is one row).
#' @param path Character. Output CSV path.
#' @return NULL. Writes to disk.
append_rows_csv <- function(rows, path) {
  df <- dplyr::bind_rows(rows)
  
  if (!fs::file_exists(path)) {
    readr::write_csv(df, path)
  } else {
    readr::write_csv(df, path, append = TRUE)
  }
  
  invisible(NULL)
}
