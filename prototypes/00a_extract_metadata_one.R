# =============================================================================
# Script: scratch/00a_extract_metadata_one.R
#
# Purpose:
#   Prototype metadata extraction on ONE WRI GeoTIFF.
#   Verifies the project assumptions that every valid file has:
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
#   - If the file passes, it extracts header metadata (no value sampling)
#     and writes a 1-row CSV.
#
# Output:
#   scratch_output/<layer_name>_metadata.csv
# =============================================================================

source("scripts/R/utils.R")

# --- Config -------------------------------------------------------------------

test_file <- "data/livelihoods/livelihoods_domain_score.tif"
out_dir   <- "scratch_output"

# Expected values (project assumptions)
expected <- list(
  epsg  = 5070,
  res_x = 90,
  res_y = 90,
  xmin  = -5216639.67,
  xmax  = -504689.6695,
  ymin  = 991231.6885,
  ymax  = 6199081.688
)

# --- Run ----------------------------------------------------------------------

if (!file.exists(test_file)) stop("File not found: ", test_file)
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

info <- get_raster_header(test_file)
if (!info$success) stop("Failed to read: ", info$error)

# Verify assumptions
if (is.na(info$crs_epsg) || info$crs_epsg != expected$epsg) {
  stop("CRS mismatch. Found: ", info$crs_epsg, ", Expected: ", expected$epsg)
}

if (!near(info$resolution_x, expected$res_x) || !near(info$resolution_y, expected$res_y)) {
  stop("Resolution mismatch. Found: ", info$resolution_x, "x", info$resolution_y)
}

if (!near(info$extent_xmin, expected$xmin) || !near(info$extent_xmax, expected$xmax) ||
    !near(info$extent_ymin, expected$ymin) || !near(info$extent_ymax, expected$ymax)) {
  stop("Extent mismatch.")
}

cat("Assumptions verified for:", basename(test_file), "\n")

# Add classification
info$data_type <- classify_data_type(test_file)
info$wri_domain <- extract_domain(test_file)
info$wri_layer_type <- classify_layer_type(info$data_type, info$filename)
info$cog_filename <- make_cog_filename(test_file)

# Save
layer_name <- tools::file_path_sans_ext(info$filename)
out_file <- file.path(out_dir, paste0(layer_name, "_metadata.csv"))
write.csv(as.data.frame(info[!names(info) %in% c("success", "error")]), out_file, row.names = FALSE)
cat("Saved:", out_file, "\n")