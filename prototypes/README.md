# Scratch / Development Scripts

This folder contains prototype scripts for testing the data processing pipeline on individual files. These are simplified versions of the production scripts in `scripts/`.

## Purpose

These scripts exist to:

1. **Test and debug** processing logic on a single file before scaling
2. **Verify settings** (e.g., GDAL options, STAC structure) work correctly
3. **Inspect outputs** in detail without waiting for batch processing
4. **Demonstrate the workflow** in meetings or documentation

## Scripts

### `00a_extract_metadata_one.R`

Tests metadata extraction on a single GeoTIFF.

**To use:**
1. Edit the `test_file` variable to point to your test layer
2. Run: `source("scratch/00a_extract_metadata_one.R")`
3. Review the console output

**Output:** Console only (no files created)

**What it shows:**
- File classification (data type, domain, layer type)
- Raster dimensions and resolution
- CRS and extent
- Value statistics (min, max, mean, NA%)
- Recommended COG resampling method

### `01a_make_cog_one.R`

Tests COG conversion on a single GeoTIFF.

**To use:**
1. Edit the `input_tif` variable to point to your test layer
2. Optionally set `resampling_method` (or leave as "auto")
3. Run: `source("scratch/01a_make_cog_one.R")`
4. Check the output in `cogs/`

**Output:** One COG file in `cogs/` directory

**What it shows:**
- The gdal_translate command being run
- Input vs output file sizes
- Compression ratio achieved
- gdalinfo output for the new COG

### `02a_make_stac_one.R`

Tests STAC metadata creation for a single COG with local file path.

**To use:**
1. First run `01a_make_cog_one.R` to create a test COG
2. Edit the `cog_path` variable to point to your test COG
3. Run: `source("prototypes/02a_make_stac_one.R")`
4. Check the output in `stac/`

**Output:** Complete STAC structure (catalog, collection, one item with local path)

**What it shows:**
- Spatial extent extraction and WGS84 transformation
- STAC JSON structure with local file href
- Full item JSON preview in console

## Relationship to Production Scripts

| Prototype Script | Production Script | Key Differences |
|------------------|-------------------|-----------------|
| `00a_extract_metadata_one.R` | `scripts/00b_extract_metadata_all.R` | Single file vs. all files |
| `01a_make_cog_one.R` | `scripts/01b_make_cog_all.R` | Single file vs. parallel batch |
| `02a_make_stac_one.R` | `scripts/02b_make_stac_all.R` | Single item (local path) vs. all items (auto-detects hosted) |

All versions use the same shared functions from `scripts/R/utils.R`.

## Development Workflow

When making changes to the processing pipeline:

1. **Test on prototype first**
   ```r
   # Modify prototypes/00a_extract_metadata_one.R with your changes
   source("prototypes/00a_extract_metadata_one.R")
   # Verify output looks correct
   ```

2. **Port to production**
   - Copy tested logic to the corresponding `scripts/` file
   - Add batch processing, logging, and progress saving

3. **Run production on subset**
   - Test on a few files before full dataset
   - Check logs for errors

## Example: Testing a New Layer

```r
# 1. Check metadata
test_file <- "data/species/indicators/species_resistance_richness.tif"
source("prototypes/00a_extract_metadata_one.R")
# Look at output - is it classified correctly?
# What resampling method does it recommend?

# 2. Convert to COG
input_tif <- "data/species/indicators/species_resistance_richness.tif"
source("prototypes/01a_make_cog_one.R")
# Check compression ratio
# Verify gdalinfo shows correct structure

# 3. Create STAC item
cog_path <- "cogs/species_resistance_richness.tif"
source("prototypes/02a_make_stac_one.R")
# Inspect the JSON output
# Verify bbox looks reasonable
```

## Notes

- These scripts are **not** designed to be re-run safely on the same file — they may overwrite outputs
- The production scripts in `scripts/` have proper skip-if-exists logic
- Always test changes here before modifying production scripts