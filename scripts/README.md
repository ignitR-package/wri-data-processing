# WRI Data Processing Scripts

This folder contains the production pipeline for processing the Wildfire Resilience Index dataset.

## Workflow Overview

The pipeline runs in sequential steps:

```text
00b_extract_metadata_all.R  →  01b_make_cog_all.R  →  02b_make_stac_all.R
                                                              ↑
                                                   (rerun after uploading
                                                    COGs to KNB)
```

Steps must run in order (each depends on the previous output). Step 02 can be rerun at any time to refresh hosting status after uploading files to KNB.

## Scripts

### `R/utils.R` — Shared Helper Functions

Contains reusable functions used across all scripts:

| Function | Purpose |
|----------|---------|
| `near()` | Compare numeric values with tolerance for floating point comparisons |
| `make_cog_filename()` | Generate unique COG filename from filepath (handles naming collisions) |
| `classify_data_type()` | Classify WRI layer data type (indicator, aggregate, final_score, exclude) |
| `extract_domain()` | Parse domain name from file path (livelihoods, biodiversity, etc.) |
| `classify_dimension()` | Classify dimension (resistance, recovery, status, domain_score) |
| `get_raster_header()` | Extract header metadata from GeoTIFF (dimensions, CRS, extent, datatype) |
| `extent_to_stac_spatial()` | Convert extent from EPSG:5070 to STAC bbox and geometry in EPSG:4326 |
| `append_rows_csv()` | Append rows to CSV for batch writing during metadata extraction |

All functions include roxygen-style documentation.

### `00b_extract_metadata_all.R` — Metadata Extraction

**Purpose:** Build a complete inventory of all WRI GeoTIFF layers with metadata.

**Inputs:**
- Raw GeoTIFF files in `data/` directory

**Outputs:**
- `metadata/all_layers_consistent.csv` — Clean, validated layers that pass all assumptions
- `metadata/all_layers_raw.csv` — Full inventory (only created if issues exist)
- `metadata/all_layers_inconsistent.csv` — Layers with assumption violations (only created if issues exist)

**Key behaviors:**
- Classifies layers as `indicator`, `aggregate`, `final_score`, or `exclude`
- Excludes files in `retro_`, `archive/`, and `final_checks/` directories
- Identifies domain from file path (e.g., `livelihoods`, `infrastructure`)
- Validates against project assumptions (EPSG:5070, 90x90m resolution, consistent extent)
- Safe to re-run: skips previously processed files
- Saves progress every 10 files in batches
- Only creates diagnostic files (raw/inconsistent CSVs) if problems are detected

**Run time:** Varies based on dataset size and I/O speed

### `01b_make_cog_all.R` — COG Conversion

**Purpose:** Convert all consistent GeoTIFFs to Cloud-Optimized GeoTIFFs.

**Inputs:**
- `metadata/all_layers_consistent.csv` (from step 00)

**Outputs:**
- `cogs/<filename>.tif` — COG files (flat directory structure)

**COG settings:**
- Format: Cloud-Optimized GeoTIFF
- Uses GDAL's COG driver with default settings
- Note: Compression options are currently commented out in the code (lines 42-45)

**Key behaviors:**
- Safe to re-run: skips existing COGs (checks if output file exists before converting)
- Error handling: catches and logs conversion failures, continues processing remaining files
- Uses metadata CSV to determine which files to convert and output filenames

**Run time:** Varies based on dataset size and system resources

### `02b_make_stac_all.R` — STAC Catalog Creation

**Purpose:** Generate STAC metadata with auto-detected KNB URLs.

**Inputs:**

- `metadata/all_layers_consistent.csv` (from step 00)
- COG files in `cogs/` directory
- KNB data repository (via HTTP HEAD requests)

**Outputs:**

- `stac/catalog.json` — Root STAC catalog
- `stac/collections/wri_ignitR/collection.json` — WRI collection
- `stac/collections/wri_ignitR/items/*.json` — One item per COG (mixed URLs)

**Key behaviors:**

- Checks each file individually via HTTP HEAD request to `https://knb.ecoinformatics.org/data/<filename>`
- Uses KNB URL if file returns 200-299 status (hosted on KNB)
- Uses local relative path if file returns error or timeout (not hosted)
- Adds `is_hosted: true/false` property to each STAC item
- Transforms spatial extent from EPSG:5070 to EPSG:4326 for STAC compliance
- Adds WRI classification properties (`data_type`, `wri_domain`, `wri_dimension`)
- Adds projection extension (`proj:epsg`)
- Single datetime for all items: `2026-06-05T00:00:00Z` (project due date)
- HTTP timeout: 5 seconds per file
- Safe to re-run: skips existing items
- Network-dependent

**Run time:** Depends on number of files and network speed (makes HTTP HEAD request per file)

**When to rerun:**

- After uploading new COGs to KNB
- Before copying STAC to `fedex` package
- Periodically as more files become hosted

## Running the Pipeline

### Full Dataset

```r
# From the repository root:

# Step 00: Extract metadata (do this first)
source("scripts/00b_extract_metadata_all.R")

# Step 01: Convert to COGs
source("scripts/01b_make_cog_all.R")

# Step 02: Create STAC catalog (auto-detects hosted vs local)
source("scripts/02b_make_stac_all.R")

# Copy to fedex package
system("cp -r stac/* ../fedex/inst/extdata/stac/")

# After uploading more COGs to KNB, rerun step 02 to refresh hosting status
```

### Checking Progress

Each script creates output files you can inspect:

```r
# Metadata extraction results
readr::read_csv("metadata/all_layers_consistent.csv")

# Check if any files failed assumptions
file.exists("metadata/all_layers_inconsistent.csv")

# COG files created
fs::dir_ls("cogs/")

# STAC items created
fs::dir_ls("stac/collections/wri_ignitR/items/")
```

### Re-running After Interruption

All scripts are designed to resume from where they left off:

- **00:** Reads existing `metadata/all_layers_raw.csv` and skips previously processed files
- **01:** Checks for existing COG files before converting
- **02:** Checks for existing STAC item JSON files before creating; re-checks KNB hosting status on each run

Just run the script again — no need to start over.

## Dependencies

### R Packages

```r
install.packages(c("terra", "sf", "dplyr", "readr", "fs", "jsonlite", "glue"))
```

### System Requirements

- **GDAL 3.x** with COG driver support
- Verify with: `gdalinfo --version` and `gdal_translate --formats | grep COG`

### Computational Resources

The pipeline was developed for the Aurora server with:
- 300+ CPU cores available (using 50 by default)
- 2 TB RAM
- Fast SSD storage

Adjust `max_threads` in `01b_make_cog_all.R` based on your system.

## Troubleshooting

### "Missing metadata CSV" error in step 01

Run `00b_extract_metadata_all.R` first to generate `metadata/all_layers_consistent.csv`.

### "Missing COG" warnings in step 02 or 03

Run `01b_make_cog_all.R` first to generate COG files. The scripts will skip items for missing COGs.

### gdal_translate not found

Ensure GDAL is installed and on your PATH:

```bash
# Ubuntu/Debian
sudo apt install gdal-bin

# macOS with Homebrew
brew install gdal

# Verify
gdal_translate --version
```

### Out of memory during metadata extraction

The `get_raster_header()` function only reads raster headers (no pixel values), so memory issues are rare. If you encounter problems:

1. Process files in smaller batches (the script already uses batch writing)
2. Check for corrupted or extremely large files
3. Increase available RAM or swap space
