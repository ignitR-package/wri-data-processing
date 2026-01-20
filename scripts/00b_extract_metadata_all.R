# =============================================================================
# Script: 00b_extract_metadata_all.R
# Purpose: Extract metadata from all WRI GeoTIFF layers and identify inconsistencies
# Author: ignitR Team (Emily, Ixel, Kaiju, Hylaea)
# Created: January 2025
# Last Modified: January 2025
#
# Description:
#   This script scans the raw WRI data directory, extracts comprehensive metadata
#   from each GeoTIFF layer, classifies files by type/domain, and performs
#   consistency checks on resolution, CRS, and extent. It produces a clean
#   metadata inventory that drives the downstream COG conversion and STAC
#   catalog creation.
#
# Inputs:
#   - Raw WRI GeoTIFF files in `data/` directory
#
# Outputs:
#   - config/all_layers_raw.csv          (full inventory including failures)
#   - config/all_layers_metadata.csv     (clean, consistent layers only)
#   - config/inconsistent_files_metadata.csv
#   - config/indicator_layers.csv
#   - config/aggregate_layers.csv
#   - config/final_score.csv
#   - config/domain_summary.csv
#   - outputs/validation_reports/*_breakdown.csv
#
# Dependencies:
#   - terra, sf, dplyr, readr, fs, glue
#   - scripts/R/utils.R (shared helper functions)
#
# Usage:
#   source("scripts/00b_extract_metadata_all.R")
#
# Notes:
#   - Safe to re-run: previously processed files are skipped
#   - Progress is saved every 10 files in case of interruption
#   - Extracting global statistics (min/max/mean) is slow (~2.5 GB per file)
# =============================================================================


# Setup ----------------------------------------------------------------------

library(terra)
library(sf)
library(dplyr)
library(readr)
library(fs)
library(glue)

# Load shared helper functions
source("scripts/R/utils.R")


# Config ---------------------------------------------------------------------

# Path to raw WRI data
raw_data_path <- "data"

# Output directories
dir_create("config")
dir_create("outputs/validation_reports")


# Load existing metadata (for re-run safety) ---------------------------------

existing_metadata <- NULL
processed_files <- character(0)

if (file_exists("config/all_layers_raw.csv")) {
  cat("Found existing metadata file\n")
  existing_metadata <- read_csv("config/all_layers_raw.csv", show_col_types = FALSE)
  processed_files <- existing_metadata$filepath
  cat("Previously processed", length(processed_files), "files\n")
}


# Find and classify all TIFF files -------------------------------------------

all_tif_files <- dir_ls(raw_data_path, recurse = TRUE, glob = "*.tif")

files_to_process <- tibble(filepath = all_tif_files) %>%
  mutate(
    # Classify by path patterns
    data_type = case_when(
      grepl("/indicators/", filepath) ~ "indicator",
      grepl("WRI_score\\.tif$", filepath) ~ "final_score",
      grepl("_(domain_score|resilience|resistance|status)\\.tif$", filepath) &
        !grepl("/indicators/|/final_checks/|/archive/|/indicators_no_mask/", filepath) ~ "aggregate",
      TRUE ~ "exclude"
    )
  ) %>%
  # Keep only the three types we want
  filter(data_type != "exclude")

cat("\nFile inventory:\n")
print(files_to_process %>% count(data_type))
cat("Total:", nrow(files_to_process), "\n")

# Skip already processed files
if (length(processed_files) > 0) {
  files_to_process <- files_to_process %>%
    filter(!filepath %in% processed_files)
  
  cat("Files remaining to process:", nrow(files_to_process), "\n")
  
  if (nrow(files_to_process) == 0) {
    cat("All files already processed. Exiting.\n")
    quit(save = "no")
  }
}


# Process files --------------------------------------------------------------

metadata_list <- vector("list", nrow(files_to_process))

for (i in seq_len(nrow(files_to_process))) {
  filepath <- files_to_process$filepath[i]
  data_type <- files_to_process$data_type[i]
  
  # Progress display
  cat(sprintf("[%d/%d] %s: %s\n",
              i, nrow(files_to_process),
              data_type,
              basename(filepath)))
  
  # Extract metadata using shared function
  info <- get_raster_info(filepath)
  info$data_type <- data_type
  
  metadata_list[[i]] <- info
  
  # Save progress every 10 files
  if (i %% 10 == 0) {
    temp_df <- bind_rows(metadata_list[1:i])
    if (!is.null(existing_metadata)) {
      temp_df <- bind_rows(existing_metadata, temp_df)
    }
    write_csv(temp_df, "config/all_layers_raw.csv")
  }
}

# Combine new with existing metadata
new_metadata <- bind_rows(metadata_list)

if (!is.null(existing_metadata)) {
  metadata_df <- bind_rows(existing_metadata, new_metadata)
} else {
  metadata_df <- new_metadata
}


# Add domain and layer type classification -----------------------------------

metadata_df <- metadata_df %>%
  mutate(
    # Extract domain using shared function
    domain = if_else(
      data_type == "final_score",
      "all_domains",
      sapply(filepath, extract_domain)
    ),
    
    # Classify layer type
    layer_type = case_when(
      # Indicators
      data_type == "indicator" & grepl("_resistance_", filename) ~ "resistance",
      data_type == "indicator" & grepl("_recovery_", filename) ~ "recovery",
      data_type == "indicator" & grepl("_status_", filename) ~ "status",
      
      # Aggregates
      data_type == "aggregate" & grepl("domain_score", filename) ~ "domain_score",
      data_type == "aggregate" & grepl("resilience", filename) ~ "resilience",
      data_type == "aggregate" & grepl("resistance", filename) ~ "resistance",
      data_type == "aggregate" & grepl("status", filename) ~ "status",
      
      # Final score has no layer type
      data_type == "final_score" ~ NA_character_,
      TRUE ~ NA_character_
    )
  ) %>%
  # Reorder columns for readability
  select(data_type, domain, layer_type, everything())


# Report on successes and failures -------------------------------------------

failures <- metadata_df %>% filter(!success)
successful_data <- metadata_df %>% filter(success)

cat("\n--- Summary ---\n")
cat("Total files:", nrow(metadata_df), "\n")
cat("Loaded successfully:", nrow(successful_data), "\n")
cat("Failed:", nrow(failures), "\n")

if (nrow(failures) > 0) {
  cat("\nFailures (showing first 30):\n")
  print(failures %>% select(data_type, domain, filename, error) %>% head(30))
}

# Save raw metadata (including failures)
write_csv(metadata_df, "config/all_layers_raw.csv")
cat("\nSaved: config/all_layers_raw.csv\n")


# Consistency checks ---------------------------------------------------------

# Determine expected values using mode (most common)
expected_res_x <- get_mode(successful_data$resolution_x)
expected_res_y <- get_mode(successful_data$resolution_y)
expected_crs <- get_mode(successful_data$crs)

# Build extent key for comparison
extent_key <- paste(
  successful_data$extent_xmin,
  successful_data$extent_xmax,
  successful_data$extent_ymin,
  successful_data$extent_ymax,
  sep = "|"
)
expected_extent_key <- get_mode(extent_key)

cat("\n--- Expected (most common) values ---\n")
cat("Resolution:", expected_res_x, "x", expected_res_y, "\n")
cat("CRS:", expected_crs, "\n")
cat("Extent key:", expected_extent_key, "\n")

# Add extent key column
successful_data <- successful_data %>%
  mutate(
    extent_key = paste(extent_xmin, extent_xmax, extent_ymin, extent_ymax, sep = "|")
  )

# Identify inconsistent files
inconsistent_files <- successful_data %>%
  filter(
    resolution_x != expected_res_x |
      resolution_y != expected_res_y |
      is.na(crs) |
      crs != expected_crs |
      extent_key != expected_extent_key
  )

# Identify consistent files
consistent_data <- successful_data %>%
  filter(
    resolution_x == expected_res_x,
    resolution_y == expected_res_y,
    !is.na(crs),
    crs == expected_crs,
    extent_key == expected_extent_key
  )

cat("\n--- Consistency check ---\n")
cat("Inconsistent files:", nrow(inconsistent_files), "\n")
cat("Consistent files:", nrow(consistent_data), "\n")

# Save inconsistent files for review
if (nrow(inconsistent_files) > 0) {
  inconsistent_metadata <- inconsistent_files %>%
    select(
      data_type, domain, layer_type, filename, filepath,
      resolution_x, resolution_y, crs,
      extent_xmin, extent_xmax, extent_ymin, extent_ymax,
      file_size_mb
    )
  
  write_csv(inconsistent_metadata, "config/inconsistent_files_metadata.csv")
  cat("Saved: config/inconsistent_files_metadata.csv\n")
}

# Save validation breakdowns
write_csv(
  successful_data %>% count(resolution_x, resolution_y) %>% arrange(desc(n)),
  "outputs/validation_reports/resolution_breakdown.csv"
)
write_csv(
  successful_data %>% count(crs) %>% arrange(desc(n)),
  "outputs/validation_reports/crs_breakdown.csv"
)
write_csv(
  successful_data %>%
    count(extent_xmin, extent_xmax, extent_ymin, extent_ymax) %>%
    arrange(desc(n)),
  "outputs/validation_reports/extent_breakdown.csv"
)

cat("Saved: outputs/validation_reports/*_breakdown.csv\n")


# Save clean metadata --------------------------------------------------------

metadata_clean <- consistent_data %>%
  select(
    data_type,
    domain,
    layer_type,
    layer_name = filename,
    filepath,
    file_size_mb,
    resolution_x,
    resolution_y,
    crs,
    extent_xmin,
    extent_xmax,
    extent_ymin,
    extent_ymax,
    value_min,
    value_max,
    na_percent,
    datatype
  ) %>%
  mutate(
    layer_name = tools::file_path_sans_ext(layer_name)
  )

write_csv(metadata_clean, "config/all_layers_metadata.csv")
cat("\nSaved: config/all_layers_metadata.csv\n")

# Save by data type
indicators <- metadata_clean %>% filter(data_type == "indicator")
aggregates <- metadata_clean %>% filter(data_type == "aggregate")
final_score <- metadata_clean %>% filter(data_type == "final_score")

if (nrow(indicators) > 0) {
  write_csv(indicators, "config/indicator_layers.csv")
  cat("Saved: config/indicator_layers.csv\n")
}
if (nrow(aggregates) > 0) {
  write_csv(aggregates, "config/aggregate_layers.csv")
  cat("Saved: config/aggregate_layers.csv\n")
}
if (nrow(final_score) > 0) {
  write_csv(final_score, "config/final_score.csv")
  cat("Saved: config/final_score.csv\n")
}

# Domain summary
domain_summary <- metadata_clean %>%
  group_by(domain, data_type) %>%
  summarise(
    n_layers = n(),
    total_size_gb = round(sum(file_size_mb) / 1024, 2),
    .groups = "drop"
  )

write_csv(domain_summary, "config/domain_summary.csv")
cat("Saved: config/domain_summary.csv\n")

cat("\n--- Done ---\n")