# Purpose:
#   Extract metadata from ALL raw WRI GeoTIFF layers and identify inconsistencies.
#
# What this script does:
#   - Recursively scans the raw data directory for GeoTIFF files.
#   - Extracts raster metadata for each file.
#   - Classifies layers by data type, domain, and layer type.
#   - Detects inconsistencies in resolution, CRS, and extent.
#   - Saves:
#       * full raw metadata (including failures),
#       * clean metadata (successful + consistent),
#       * a table of inconsistent files for follow-up.
#
# What this script does NOT do:
#   - It does not modify raster data.
#   - It does not convert files to COGs.
#   - It does not create STAC metadata.
#
# Important behavior:
#   - This script is safe to re-run.
#   - Previously processed files are skipped using the saved metadata CSV.
#
# Why this script exists:
#   This step establishes a complete and auditable inventory of the dataset
#   before any transformations are performed.
#
# Inputs:
#   - Raw WRI GeoTIFF files.
#
# Outputs:
#   - config/all_layers_raw.csv
#   - config/all_layers_metadata.csv
#   - config/inconsistent_files_metadata.csv
#   - summary CSVs by domain and data type

# Load packages
library(terra)
library(sf)
library(dplyr)
library(readr)
library(fs)
library(glue)



# Config ------------------------------------------------------------------

# Path to data on Aurora
raw_data_path = "data"

# Create output directories
dir_create("config")
dir_create("outputs/validation_reports")


# Helper functions --------------------------------------------------------

# ADD DOCUMENTATION TO THESE HELPER FUNCTIONS LATER

# Mode function, returns the most common value in a vector
get_mode <- function(x) {
  # Remove missing values
  x <- x[!is.na(x)]
  
  # Count how many times each value appears
  counts <- table(x)
  
  # Find most freq
  mode_value <- names(counts)[which.max(counts)]
  
  return(mode_value)
}


# Define function to extract the domain name of the file
extract_domain <- function(filepath) {
  path_parts <- strsplit(filepath, "/")[[1]]
  
  # Known domain directories
  domain_dirs <- c("air_quality", "biodiversity", "carbon", "communities", 
                   "infrastructure", "livelihoods", "natural_habitats", 
                   "sense_of_place", "sensitivity_analysis", "species", "water")
  
  # Identify the part that contains 'indicator' (that will be the domain name)
  indicators_idx <- which(path_parts == "indicators")
  # Get the directory before indicators
  if (length(indicators_idx) > 0) {
    domain_idx <- indicators_idx[1] - 1
    if (domain_idx > 0) {
      return(path_parts[domain_idx])
    }
  }
  
  # Otherwise, check all path parts
  for (domain in domain_dirs) {
    if (any(grepl(domain, path_parts))) {
      return(domain)
    }
  }
  
  # Finally, check filename
  filename <- basename(filepath)
  for(domain in domain_dirs) {
    if (grepl(domain, filename)) {
      return(domain)
    }
  }
  
  # If no result, return unknown
  return("unknown")
}

# Function to get info about a single raster file
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


# Load existing metadata (if any) -----------------------------------------

# Initialize existing_metadata and processed_files
existing_metadata <- NULL
processed_files <- character(0)

# Determine how many files have been processed
if (file_exists("config/all_layers_raw.csv")) {
  cat("Found existing metadata file")
  existing_metadata <- read_csv("config/all_layers_raw.csv", show_col_types = FALSE)
  processed_files <- existing_metadata$filepath
  cat("Previously processed", length(processed_files), "files")
}

# Find all TIFF files and classify them -----------------------------------

# Find all TIFF files
all_tif_files <- dir_ls(raw_data_path,
                        recurse = TRUE,
                        glob = "*.tif")

# Categorize files by path patterns
files_to_process <- tibble(filepath = all_tif_files) %>%
  mutate(
    # Determine data type from path
    data_type = case_when(
      grepl("/indicators/", filepath) ~ "indicator",
      grepl("WRI_score\\.tif$", filepath) ~ "final_score",
      grepl("_(domain_score|resilience|resistance|status)\\.tif$", filepath) & 
        !grepl("/indicators/|/final_checks/|/archive/|/indicators_no_mask/", filepath) ~ "aggregate",
      TRUE ~ "exclude"
    )
  ) %>%
  # Only keep the three types we want
  filter(data_type != "exclude")

cat("File inventory:\n")
print(files_to_process %>% count(data_type))
cat("Total:", nrow(files_to_process), "\n")

# Filter out already processed files
if (length(processed_files) > 0) {
  files_to_process <- files_to_process %>% 
    filter(!filepath %in% processed_files)
  
  cat("Files remaining to process:", nrow(files_to_process))
  if (nrow(files_to_process) == 0) {
    cat("All files have already been processed. Nothing to do.\n")
    return()  
  }
}


# Process files loop ------------------------------------------------------

metadata_list <- vector("list", nrow(files_to_process))

for (i in seq_len(nrow(files_to_process))) {
  filepath <- files_to_process$filepath[i]
  data_type <- files_to_process$data_type[i]
  
  # Display progress
  cat(sprintf("[%d/%d] %s: %s\n", 
                i, nrow(files_to_process), 
                data_type, 
                basename(filepath)))
  
  # Get raster metadata
  info <- get_raster_info(filepath)
  
  # Add data type
  info$data_type <- data_type
  
  metadata_list[[i]] <- info
  
  # Save progress every 10 files
  if (i %% 10 == 0) {                         # if 10 goes into i evenly
    temp_df <- bind_rows(metadata_list[1:i])  # bind metadata rows into temp_df
    if (!is.null(existing_metadata)) {
      temp_df <- bind_rows(existing_metadata, temp_df) # Add temp_df into existing_metadata
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


# Add domain and layer name -----------------------------------------------

metadata_df <- metadata_df %>% 
  mutate(
    # Extract domain
    domain = if_else(data_type == "final_score",
                     "all_domains",
                     sapply(filepath, extract_domain)),
    
    # Distinguish layer type
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
      
      # Final score (no layer type)
      data_type == "final_score" ~ NA_character_,
      TRUE ~ NA_character_
    )
  ) %>% 
  # Reorder columns
  select(data_type, domain, layer_type, everything())


# Basic report ------------------------------------------------------------

failures <- metadata_df %>% filter(!success)
successful_data <- metadata_df %>% filter(success)

# Print success and failures
cat("\nSummary:\n")
cat("Total files:", nrow(metadata_df), "\n")
cat("Loaded:", nrow(successful_data), "\n")
cat("Failed:", nrow(failures), "\n")

if (nrow(failures) > 0) {
  cat("\nFailures (showing first 30):\n")
  print(failures %>% select(data_type, domain, filename, error) %>% head(30))
}

# Save the raw metadata (including failures)
write_csv(metadata_df, "config/all_layers_raw.csv")
cat("Saved: config/all_layers_raw.csv\n")


# Res, CRS, and Ext Consistency Checks ------------------------------------

# Expected values:
# Use the most common (mode) values among loaded rasters.
expected_res_x <- get_mode(successful_data$resolution_x)
expected_res_y <- get_mode(successful_data$resolution_y)
expected_crs <- get_mode(successful_data$crs)

# Build extent key and take mode
extent_key <- paste(
  successful_data$extent_xmin,
  successful_data$extent_xmax,
  successful_data$extent_ymin,
  successful_data$extent_ymax,
  sep = "|"
)
expected_extent_key <- get_mode(extent_key)

# Check 
cat("\nExpected (most common) values:\n")
cat("Resolution:", expected_res_x, "x", expected_res_y, "\n")
cat("CRS:", expected_crs, "\n")
cat("Extent key:", expected_extent_key, "\n\n")

# Add a per-file extent key for checks
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

cat("Found", nrow(inconsistent_files), "inconsistent files\n")
cat("Found", nrow(consistent_data), "consistent files\n")

# Save the inconsistent file list (separate output)
if (nrow(inconsistent_files) > 0) {
  inconsistent_metadata <- inconsistent_files %>%
    select(
      data_type,
      domain,
      layer_type,
      filename,
      filepath,
      resolution_x,
      resolution_y,
      crs,
      extent_xmin,
      extent_xmax,
      extent_ymin,
      extent_ymax,
      file_size_mb
    )
  
  write_csv(inconsistent_metadata, "config/inconsistent_files_metadata.csv")
  cat("Saved: config/inconsistent_files_metadata.csv\n")
}

# Save some simple breakdown CSVs
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


# Save clean metadata (consistent only) -----------------------------------

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
cat("Saved: config/all_layers_metadata.csv\n")

# Save organized by data type (consistent only)
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

# Domain summary (kept simple: one row per domain and data_type)
domain_summary <- metadata_clean %>%
  group_by(domain, data_type) %>%
  summarise(
    n_layers = n(),
    total_size_gb = round(sum(file_size_mb) / 1024, 2),
    .groups = "drop"
  )

write_csv(domain_summary, "config/domain_summary.csv")
cat("Saved: config/domain_summary.csv\n")