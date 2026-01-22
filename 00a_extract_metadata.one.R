# =============================================================================
# scratch/00a_extract_metadata_one.R
# Purpose: Extract basic metadata for one WRI GeoTIFF and save to CSV
# =============================================================================

library(terra)

# --- Config ---
test_file <- "data/livelihoods/livelihoods_domain_score.tif"
out_dir   <- "scratch_output"

# --- Helpers ---

#' Guess variable type (categorical or continuous)
#'
#' Uses a numeric vector of values to guess whether the variable
#' represents categorical or continuous data.
#' 
#' We include this as resampling methods for categorical and 
#' continuous should be different when converting COGS
#'
#' @param x Numeric vector of values (e.g. sampled raster cells)
#' @param num_category_threshold Maximum number of unique values allowed
#'   to still be considered categorical
#' @param int_tolerance Tolerance used to decide if values are essentially integers
#'
#' @return Character string: "categorical" or "continuous"
guess_variable_type <- function(x, num_category_threshold = 50, int_tolerance = 1e-8) {
  # x is a numeric vector (sampled raster values)
  x <- x[!is.na(x)]
  if (length(x) == 0) return(NA_character_)
  
  # Count as an int if values are close enough to integers ('close enough' defined by `int_tolerance`)
  is_integerish <- all(abs(x - round(x)) < int_tolerance)
  
  # unique count on sample
  u <- length(unique(x))
  
  if (is_integerish && u <= unique_threshold) "categorical" else "continuous"
}

# --- Run ---

# Check if the test_file exists
if (!file.exists(test_file)) stop("File not found: ", test_file)

# Create the directory 
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

# Load in test_file
r <- rast(test_file)

# Extract basic metadata
info <- list(
  filepath        = test_file,
  filename        = basename(test_file),
  nrows           = nrow(r),
  ncols           = ncol(r),
  ncells          = ncell(r),
  nlayers         = nlyr(r),
  resolution_x    = res(r)[1],
  resolution_y    = res(r)[2],
  crs             = crs(r),
  extent_xmin     = ext(r)[1],
  extent_xmax     = ext(r)[2],
  extent_ymin     = ext(r)[3],
  extent_ymax     = ext(r)[4],
  datatype        = terra::datatype(r),
  file_size_mb    = round(file.info(test_file)$size / 1024^2, 2)
)

# Sample values instead of doing global statistics
set.seed(1)
samp <- terra::spatSample(r, size = 200000, method = "random", na.rm = FALSE, as.df = TRUE)[, 1]
samp <- as.numeric(samp)

info$value_min   <- suppressWarnings(min(samp, na.rm = TRUE))
info$value_max   <- suppressWarnings(max(samp, na.rm = TRUE))
info$value_mean  <- suppressWarnings(mean(samp, na.rm = TRUE))
info$na_percent  <- round(mean(is.na(samp)) * 100, 3)
info$var_type    <- guess_variable_type(samp)

# Save a one-row CSV
out_file <- file.path(out_dir, paste0(tools::file_path_sans_ext(info$filename), "_metadata.csv"))
write.csv(as.data.frame(info), out_file, row.names = FALSE)

cat("Saved metadata to:", out_file, "\n")
