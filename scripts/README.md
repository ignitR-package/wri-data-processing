# [UPDATE THIS README]

# WRI Data Processing Scripts

This folder contains the production pipeline for processing the Wildfire Resilience Index dataset.

## Workflow Overview

The pipeline runs in sequential steps:

```
00b_extract_metadata_all.R  →  01b_make_cog_all.R  →  02b_make_stac_all.R
                                                       ↓
                                          [Upload COGs to KNB]
                                                       ↓
                                          03b_make_stac_hybrid_all.R
```

- **Steps 00-02** must run in order (each depends on the previous output)
- **Step 03** runs independently after manual file uploads to KNB

## Scripts

### `R/utils.R` — Shared Helper Functions

Contains reusable functions used across all scripts:

| Function | Purpose |
|----------|---------|
| `get_mode()` | Find most common value in a vector |
| `extract_domain()` | Parse domain name from file path |
| `get_raster_info()` | Extract comprehensive metadata from a GeoTIFF |
| `choose_resampling()` | Select AVERAGE or NEAREST for COG overviews |
| `make_item_id()` | Generate STAC item ID from file path |
| `get_item_spatial()` | Extract bbox and geometry in WGS84 for STAC |
| `bbox_union()` | Combine multiple bounding boxes |

All functions include roxygen-style documentation.

### `00b_extract_metadata_all.R` — Metadata Extraction

**Purpose:** Build a complete inventory of all WRI GeoTIFF layers with metadata.

**Inputs:**
- Raw GeoTIFF files in `data/` directory

**Outputs:**
- `config/all_layers_raw.csv` — Full inventory including failed reads
- `config/all_layers_metadata.csv` — Clean, consistent layers only
- `config/inconsistent_files_metadata.csv` — Layers with issues
- `config/indicator_layers.csv` — Subset: indicator layers
- `config/aggregate_layers.csv` — Subset: aggregate layers
- `config/final_score.csv` — Subset: final WRI score
- `config/domain_summary.csv` — Count and size by domain
- `outputs/validation_reports/*_breakdown.csv` — Resolution/CRS/extent reports

**Key behaviors:**
- Classifies layers as `indicator`, `aggregate`, or `final_score`
- Identifies domain from file path (e.g., `livelihoods`, `infrastructure`)
- Detects inconsistencies in resolution, CRS, or extent
- Safe to re-run: skips previously processed files
- Saves progress every 10 files

**Run time:** ~30-60 minutes for full dataset (depends on I/O speed)

### `01b_make_cog_all.R` — COG Conversion

**Purpose:** Convert all consistent GeoTIFFs to Cloud-Optimized GeoTIFFs.

**Inputs:**
- `config/all_layers_metadata.csv` (from step 00)

**Outputs:**
- `cogs/<data_type>/<domain>/<filename>.tif` — Organized COG files
- `outputs/validation_reports/cog_conversion_log.csv` — Conversion status log

**COG settings:**
- Format: Cloud-Optimized GeoTIFF
- Compression: DEFLATE (lossless)
- Tile size: 512×512 pixels
- Overviews: Internal, auto-generated
- Resampling: AVERAGE (continuous) or NEAREST (categorical)
- Threads: 50 (configurable via `max_threads`)

**Key behaviors:**
- Automatically selects resampling based on layer type and data type
- Safe to re-run: skips existing COGs
- Saves progress every 25 files

**Run time:** ~2-4 hours for full dataset (CPU-intensive)

### `02b_make_stac_all.R` — STAC Catalog Creation (Local)

**Purpose:** Generate STAC metadata with local file paths for development.

**Inputs:**
- `metadata/all_layers_consistent.csv` (from step 00)
- COG files in `cogs/` directory

**Outputs:**
- `stac/catalog.json` — Root STAC catalog
- `stac/collections/wri_ignitR/collection.json` — WRI collection
- `stac/collections/wri_ignitR/items/*.json` — One item per COG (local paths)

**Key behaviors:**
- Uses relative local file paths for all assets (e.g., `../cogs/WRI_score.tif`)
- Extracts spatial extent from metadata and transforms to WGS84
- Adds WRI classification properties (domain, data_type, layer_type)
- Safe to re-run: skips existing items
- No network calls (fast)

**Run time:** ~1-5 minutes for full dataset

### `03b_make_stac_hybrid_all.R` — STAC Catalog Creation (Production)

**Purpose:** Generate STAC metadata with auto-detected KNB URLs for production.

**Inputs:**
- `metadata/all_layers_consistent.csv` (from step 00)
- COG files in `cogs/` directory (for local fallback)
- KNB data repository (via HTTP HEAD requests)

**Outputs:**
- `stac/catalog.json` — Root STAC catalog
- `stac/collections/wri_ignitR/collection.json` — WRI collection
- `stac/collections/wri_ignitR/items/*.json` — One item per COG (mixed URLs)

**Key behaviors:**
- Checks each file individually via HTTP HEAD to `https://knb.ecoinformatics.org/data/<filename>`
- Uses KNB URL if file returns 200 status (hosted)
- Uses local path if file returns 404 or timeout (not hosted)
- Adds `is_hosted: true/false` property to each STAC item
- Safe to re-run: skips existing items
- Network calls (slower than 02b)

**Run time:** ~5-15 minutes for full dataset (depends on network speed)

**When to use:**
- After uploading any COGs to KNB
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

# Step 02: Create STAC catalog (local development)
source("scripts/02b_make_stac_all.R")

# [Manual step: Upload COGs to KNB via DataONE portal or API]

# Step 03: Create STAC catalog (production with hosted URLs)
source("scripts/03b_make_stac_hybrid_all.R")

# Copy to fedex package
system("cp -r stac/* ../fedex/inst/extdata/stac/")
```

### Checking Progress

Each script creates log files you can inspect:

```r
# Metadata extraction progress
readr::read_csv("config/all_layers_raw.csv")

# COG conversion progress
readr::read_csv("outputs/validation_reports/cog_conversion_log.csv")

# STAC items created
fs::dir_ls("stac/collections/wri_ignitR/items/")
```

### Re-running After Interruption

All scripts are designed to resume from where they left off:

- **00:** Reads existing metadata CSV and skips processed files
- **01:** Checks for existing COGs before converting
- **02:** Checks for existing STAC items before creating
- **03:** Checks for existing STAC items before creating; re-checks hosting status

Just run the script again — no need to start over.

### When to Rerun Step 03

You should rerun `03b_make_stac_hybrid_all.R` when:
- ✅ You've uploaded new files to KNB
- ✅ Before updating the `fedex` package
- ✅ When testing hosting status changes
- ❌ Not needed if only local files changed

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

### "Missing metadata file" error in step 01

Run `00b_extract_metadata_all.R` first to generate the metadata inventory.

### "Missing conversion log" error in step 02

Run `01b_make_cog_all.R` first to generate the COG conversion log.

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

The `get_raster_info()` function computes global statistics which requires loading the full raster. For very large files, consider:

1. Reducing the number of concurrent processes
2. Processing in smaller batches
3. Skipping value statistics (modify `utils.R`)