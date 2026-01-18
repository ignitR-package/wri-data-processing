# Purpose: 01b Convert ALL consistent WRI GeoTIFFs to COGs (batch)

library(readr)
library(dplyr)
library(fs)


# Config ------------------------------------------------------------------

metadata_path <- "config/all_layers_metadata.csv"
cog_root <- "cogs"
log_path <- "outputs/validation_reports/cog_conversion_log.csv"

# Cluster policy
max_threads <- 50

# Make sure folders exist
dir_create(cog_root)
dir_create(path_dir(log_path))


# Read metadata -----------------------------------------------------------

if (!file_exists(metadata_path)) {
  stop(paste("Missing file:", metadata_path))
}

meta <- read_csv(metadata_path, show_col_types = FALSE)

if (!("filepath" %in% names(meta))) stop("metadata is missing column: filepath")
if (!("filename" %in% names(meta)) && !("layer_name" %in% names(meta))) {
  # not fatal, but we will use basename(filepath)
  cat("Note: metadata has no filename/layer_name column, using basename(filepath)\n")
}

# Optional columns we might use
has_data_type <- "data_type" %in% names(meta)
has_domain <- "domain" %in% names(meta)
has_layer_type <- "layer_type" %in% names(meta)
has_datatype <- "datatype" %in% names(meta)


# Helper functions --------------------------------------------------------

# Choose resampling for overviews based on very simple rules
choose_resampling <- function(layer_type, datatype_str) {
  
  # Rule 1: status layers are categorical
  if (!is.na(layer_type) && layer_type == "status") {
    return("NEAREST")
  }
  
  # Rule 2: integer rasters are probably categorical or discrete
  # terra::datatype often looks like "INT2S", "INT4S", "FLT4S", etc.
  if (!is.na(datatype_str)) {
    if (grepl("INT|UINT|SINT", datatype_str)) {
      return("NEAREST")
    }
  }
  
  # Otherwise treat as continuous
  return("AVERAGE")
}

# Build output COG path
# Layout: cogs/<data_type>/<domain>/<basename>.tif
make_out_path <- function(data_type, domain, in_path) {
  out_dir <- path(cog_root, data_type, domain)
  dir_create(out_dir)
  path(out_dir, path_file(in_path))
}


# Batch convert -----------------------------------------------------------

results <- vector("list", nrow(meta))

for (i in seq_len(nrow(meta))) {
  
  in_path <- meta$filepath[i]
  
  # Pick labels if available, else fallback
  data_type <- if (has_data_type) meta$data_type[i] else "unknown"
  domain <- if (has_domain) meta$domain[i] else "unknown"
  
  # Some metadata files may have layer_type / datatype
  layer_type <- if (has_layer_type) meta$layer_type[i] else NA
  datatype_str <- if (has_datatype) meta$datatype[i] else NA
  
  # Determine resampling method for overviews
  resampling <- choose_resampling(layer_type, datatype_str)
  
  out_path <- make_out_path(data_type, domain, in_path)
  
  # Progress message
  cat(sprintf("[%d/%d] %s -> %s\n", i, nrow(meta), path_file(in_path), resampling))
  
  status <- "unknown"
  message <- ""
  
  # Skip if already exists
  if (file_exists(out_path)) {
    status <- "skipped_exists"
    message <- "COG already exists"
  } else {
    
    # Build gdal_translate command (same core options as 01a)
    cmd <- paste(
      "gdal_translate",
      "-of COG",
      "-co COMPRESS=DEFLATE",
      "-co PREDICTOR=YES",
      "-co BLOCKSIZE=512",
      paste0("-co RESAMPLING=", resampling),
      "-co OVERVIEWS=IGNORE_EXISTING",
      paste0("-co NUM_THREADS=", max_threads),
      shQuote(in_path),
      shQuote(out_path)
    )
    
    # Run it
    out <- try(system(cmd, intern = TRUE), silent = TRUE)
    
    if (inherits(out, "try-error")) {
      status <- "failed"
      message <- as.character(out)
    } else {
      status <- "converted"
      message <- "ok"
    }
  }
  
  results[[i]] <- tibble(
    i = i,
    input = in_path,
    output = out_path,
    data_type = data_type,
    domain = domain,
    layer_type = layer_type,
    datatype = datatype_str,
    resampling = resampling,
    status = status,
    message = message
  )
  
  # Save progress every 25 rows so you have a log even if it stops mid-way
  if (i %% 25 == 0) {
    temp_log <- bind_rows(results[1:i])
    write_csv(temp_log, log_path)
  }
}

log_df <- bind_rows(results)
write_csv(log_df, log_path)

cat("\nDone.\n")
cat("Wrote log:", log_path, "\n\n")

cat("Summary:\n")
print(log_df %>% count(status))

cat("\nResampling summary:\n")
print(log_df %>% count(resampling, status))
