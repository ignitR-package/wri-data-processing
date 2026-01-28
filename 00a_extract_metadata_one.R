# =============================================================================
# Script: scratch/00a_extract_metadata_one.R
#
# Purpose:
#   Prototype metadata extraction on ONE WRI GeoTIFF.
#   This script also verifies the project assumptions that every valid file has:
#     - EPSG:5070
#     - resolution 90 x 90 (meters)
#     - extent:
#         xmin = -5216639.67
#         xmax =  -504689.6695
#         ymin =   991231.6885
#         ymax =  6199081.688
#
# Behavior:
#   - If the file violates any assumption, the script stops with a clear error.
#   - If the file passes, it extracts metadata and sample-based value summaries,
#     then writes a 1-row CSV.
#
# Output:
#   scratch_output/<layer_name>_metadata.csv
# =============================================================================

library(terra)

# --- Config ---------------------------------------------------------------

test_file <- "data/livelihoods/livelihoods_domain_score.tif"
out_dir   <- "scratch_output"

# Expected (project assumptions)
expected_epsg <- 5070
expected_res_x <- 90
expected_res_y <- 90

expected_xmin <- -5216639.67
expected_xmax <-  -504689.6695
expected_ymin <-   991231.6885
expected_ymax <-  6199081.688

# Sampling for value summaries
sample_size <- 200000
set.seed(1)

# --- Helpers --------------------------------------------------------------

# Compare numeric values with a small tolerance to avoid false mismatches
near <- function(a, b, tol = 1e-6) {
  isTRUE(all.equal(as.numeric(a), as.numeric(b), tolerance = tol))
}

# --- Run ------------------------------------------------------------------

if (!file.exists(test_file)) stop("File not found: ", test_file)
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

# Load raster
r <- rast(test_file)

# --- Verify assumptions (stop if any fail) -------------------------------

# EPSG code (prefer describe=TRUE because it returns code cleanly when available)
epsg <- NA_integer_
crs_desc <- suppressWarnings(try(terra::crs(r, describe = TRUE), silent = TRUE))
if (!inherits(crs_desc, "try-error") && "code" %in% names(crs_desc)) {
  epsg <- as.integer(crs_desc$code)
}

if (is.na(epsg)) {
  stop("CRS EPSG code is NA (could not be read). Expected EPSG:", expected_epsg)
}
if (epsg != expected_epsg) {
  stop("CRS EPSG mismatch. Found EPSG:", epsg, " Expected EPSG:", expected_epsg)
}

rx <- res(r)[1]
ry <- res(r)[2]
if (!near(rx, expected_res_x) || !near(ry, expected_res_y)) {
  stop(
    "Resolution mismatch. Found (",
    rx, ", ", ry,
    ") Expected (",
    expected_res_x, ", ", expected_res_y,
    ")."
  )
}

e <- ext(r)
xmin <- e[1]; xmax <- e[2]; ymin <- e[3]; ymax <- e[4]

if (!near(xmin, expected_xmin) ||
    !near(xmax, expected_xmax) ||
    !near(ymin, expected_ymin) ||
    !near(ymax, expected_ymax)) {
  stop(
    "Extent mismatch.\n",
    "Found:    ", xmin, ", ", xmax, ", ", ymin, ", ", ymax, "\n",
    "Expected: ", expected_xmin, ", ", expected_xmax, ", ",
    expected_ymin, ", ", expected_ymax
  )
}

cat("Assumptions verified for:", basename(test_file), "\n")

# --- Extract metadata -----------------------------------------------------

info <- list(
  filepath        = test_file,
  filename        = basename(test_file),
  
  nrows           = nrow(r),
  ncols           = ncol(r),
  ncells          = ncell(r),
  nlayers         = nlyr(r),
  
  resolution_x    = rx,
  resolution_y    = ry,
  
  crs_epsg        = epsg,
  crs_full        = as.character(crs(r)),
  
  extent_xmin     = xmin,
  extent_xmax     = xmax,
  extent_ymin     = ymin,
  extent_ymax     = ymax,
  
  datatype        = terra::datatype(r)[1],
  file_size_mb    = round(file.info(test_file)$size / 1024^2, 2)
)

# --- Sample values for summary stats --------------------------------------

samp <- terra::spatSample(
  r,
  size   = sample_size,
  method = "random",
  na.rm  = FALSE,
  as.df  = TRUE
)[, 1]

samp <- as.numeric(samp)

info$value_min  <- suppressWarnings(min(samp, na.rm = TRUE))
info$value_max  <- suppressWarnings(max(samp, na.rm = TRUE))
info$value_mean <- suppressWarnings(mean(samp, na.rm = TRUE))
info$na_percent <- round(mean(is.na(samp)) * 100, 3)

# Optional: keep if you still want it
info$var_type <- "continuous"

# --- Save CSV -------------------------------------------------------------

layer_name <- tools::file_path_sans_ext(info$filename)
out_file <- file.path(out_dir, paste0(layer_name, "_metadata.csv"))

write.csv(as.data.frame(info), out_file, row.names = FALSE)

cat("Saved metadata to:", out_file, "\n")
