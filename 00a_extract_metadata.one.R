# Purpose:
#   Proof-of-concept script for extracting metadata from a single WRI GeoTIFF.
#
# What this script does:
#   - Reads one GeoTIFF layer from disk.
#   - Extracts basic raster metadata (dimensions, resolution, CRS, extent).
#   - Computes simple value summaries (min, max, NA percent).
#   - Classifies the layer by data type, domain, and layer type based on filename/path.
#
# What this script does NOT do:
#   - It does not write any STAC files.
#   - It does not modify or convert the raster.
#   - It does not loop over multiple files.
#
# Why this script exists:
#   This file is a small, safe test case used to develop and debug the metadata
#   extraction logic before scaling up to all layers (00b).
#
# Inputs:
#   - One GeoTIFF file on disk.
#
# Outputs:
#   - Printed metadata to the console only.
# Load packages
library(terra)
library(dplyr)
library(fs)

# Config ------------------------------------------------------------------

test_file <- "data/livelihoods/livelihoods_domain_score.tif"


# Helper functions --------------------------------------------------------

# Extract domain name from file path 
extract_domain <- function(filepath) {
  path_parts <- strsplit(filepath, "/")[[1]]
  
  domain_dirs <- c(
    "air_quality", "biodiversity", "carbon", "communities",
    "infrastructure", "livelihoods", "natural_habitats",
    "sense_of_place", "sensitivity_analysis", "species", "water"
  )
  
  # Get directory before indicators
  indicators_idx <- which(path_parts == "indicators")
  if (length(indicators_idx) > 0) {
    domain_idx <- indicators_idx[1] - 1
    if (domain_idx > 0) {
      return(path_parts[domain_idx])
    }
  }
  
  # Otherwise, look for known domain names in the path
  for (domain in domain_dirs) {
    if (any(grepl(domain, path_parts))) {
      return(domain)
    }
  }
  
  # Then try filename
  filename <- basename(filepath)
  for (domain in domain_dirs) {
    if (grepl(domain, filename)) {
      return(domain)
    }
  }
  
  # Else unknown
  return("unknown")
}

# Read raster and extract metadata
get_raster_info <- function(filepath) {
  tryCatch({
    r <- rast(filepath)
    
    # Global stats (slow)
    vmin <- global(r, "min", na.rm = TRUE)[1, 1]
    vmax <- global(r, "max", na.rm = TRUE)[1, 1]
    vmean <- global(r, "mean", na.rm = TRUE)[1, 1]
    
    info <- list(
      filepath = filepath,
      filename = basename(filepath),
      file_size_mb = round(file_size(filepath) / (2^20), 2),
      ncols = ncol(r),
      nrows = nrow(r),
      ncells = ncell(r),
      nlayers = nlyr(r),
      resolution_x = res(r)[1],
      resolution_y = res(r)[2],
      crs = crs(r, describe = TRUE)$code,
      crs_full = as.character(crs(r)),
      extent_xmin = ext(r)[1],
      extent_xmax = ext(r)[2],
      extent_ymin = ext(r)[3],
      extent_ymax = ext(r)[4],
      value_min = vmin,
      value_max = vmax,
      value_mean = vmean,
      na_cells = freq(r, value = NA)$count[1],
      na_percent = round((freq(r, value = NA)$count[1] / ncell(r)) * 100, 2),
      datatype = datatype(r)[1],
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


# Extract metadata --------------------------------------------------------

metadata <- get_raster_info(test_file)

if (!metadata$success) {
  stop(paste("Failed to read file:", metadata$error))
}

cat("Successfully read file\n\n")


# Classify file -----------------------------------------------------------

# Determine data type from path / filename
data_type <- case_when(
  grepl("/indicators/", metadata$filepath) ~ "indicator",
  grepl("WRI_score\\.tif$", metadata$filepath) ~ "final_score",
  grepl("_(domain_score|resilience|resistance|status)\\.tif$", metadata$filepath) ~ "aggregate",
  TRUE ~ "unknown"
)

# Extract domain
domain <- if (data_type == "final_score") {
  "all_domains"
} else {
  extract_domain(metadata$filepath)
}

# Extract layer type
layer_type <- case_when(
  # Indicators
  data_type == "indicator" & grepl("_resistance_", metadata$filename) ~ "resistance",
  data_type == "indicator" & grepl("_recovery_", metadata$filename) ~ "recovery",
  data_type == "indicator" & grepl("_status_", metadata$filename) ~ "status",
  
  # Aggregates
  data_type == "aggregate" & grepl("domain_score", metadata$filename) ~ "domain_score",
  data_type == "aggregate" & grepl("resilience", metadata$filename) ~ "resilience",
  data_type == "aggregate" & grepl("resistance", metadata$filename) ~ "resistance",
  data_type == "aggregate" & grepl("status", metadata$filename) ~ "status",
  
  # Final score has no layer_type
  TRUE ~ NA_character_
)

cat("File categorization:\n")
cat("  Data type:", data_type, "\n")
cat("  Domain:", domain, "\n")
if (!is.na(layer_type)) {
  cat("  Layer type:", layer_type, "\n")
}
cat("\n")


# View results ------------------------------------------------------------

cat("File:", metadata$filename, "\n")
cat("Size:", metadata$file_size_mb, "MB\n")
cat("Raster datatype:", metadata$datatype, "\n\n")

cat("Dimensions:\n")
cat("  Rows:", metadata$nrows, "\n")
cat("  Cols:", metadata$ncols, "\n")
cat("  Cells:", format(metadata$ncells, big.mark = ","), "\n")
cat("  Layers:", metadata$nlayers, "\n\n")

cat("Resolution:\n")
cat("  X:", metadata$resolution_x, "\n")
cat("  Y:", metadata$resolution_y, "\n\n")

cat("CRS:\n")
cat("  Code:", metadata$crs, "\n\n")

cat("Extent:\n")
cat("  X range:", metadata$extent_xmin, "to", metadata$extent_xmax, "\n")
cat("  Y range:", metadata$extent_ymin, "to", metadata$extent_ymax, "\n\n")

cat("Data values:\n")
cat("  Value range:", metadata$value_min, "to", metadata$value_max, "\n")
cat("  Mean:", round(metadata$value_mean, 2), "\n")
cat("  Missing data (%):", metadata$na_percent, "\n\n")
