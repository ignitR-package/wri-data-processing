# Wildfire Resilience Index (WRI) Data Processing

This repository contains the data processing pipeline for converting the Wildfire Resilience Index (WRI) dataset into a cloud-accessible format. The pipeline transforms raw GeoTIFF layers into Cloud-Optimized GeoTIFFs (COGs) with STAC metadata for discovery and access.

The workflow is intentionally split into small, explicit steps. Expensive operations (reading large rasters) happen once, and all later steps rely on saved metadata.

---

## High-level Workflow

The pipeline has three automated steps plus one manual upload step:

```
┌─────────────────────────────────────────────────────────────────┐
│  Step 00: Extract & validate metadata from raw GeoTIFFs        │
│           → metadata/all_layers_consistent.csv                 │
├─────────────────────────────────────────────────────────────────┤
│  Step 01: Convert validated rasters to Cloud-Optimized GeoTIFFs│
│           → cogs/*.tif                                         │
├─────────────────────────────────────────────────────────────────┤
│  (Manual) Upload COGs to KNB as they become ready              │
├─────────────────────────────────────────────────────────────────┤
│  Step 02: Generate STAC catalog (auto-detects hosted vs local) │
│           → stac/ (KNB URLs for hosted files, local paths      │
│              for the rest) → copy to fedex package              │
└─────────────────────────────────────────────────────────────────┘
```

Each step reads the output of the previous one. The metadata CSV is the single source of truth — expensive raster I/O happens once in Step 00, and everything downstream uses the CSV.

Step 02 produces a "hybrid" STAC: it checks KNB for each file via HTTP HEAD and uses the hosted URL if available, falling back to a local path otherwise. This means you can run it at any point — before any uploads, after some, or after all — and get a valid catalog.

---

## Design Principles

- **Single source of truth** via metadata CSVs
- **Explicit spatial assumptions** enforced once
- **Prototype (`a`) scripts** mirrored by **production (`b`) scripts**
- **Rerun-safe**, non-interactive execution
- **Local development** with path to **hosted production**

---

## Directory Structure

```text
wri-data-processing/
├── data/              # Raw input GeoTIFFs
├── metadata/          # Metadata CSVs (source of truth)
├── cogs/              # Output Cloud Optimized GeoTIFFs
├── stac/              # STAC catalog (auto-detected URLs)
├── scratch_output/    # Temporary/intermediate outputs
├── prototypes/        # Single-file workflow tests (*a.R)
│   ├── 00a_extract_metadata_one.R
│   ├── 01a_make_cog_one.R
│   └── 02a_make_stac_one.R
├── experiments/       # Performance testing, benchmarks, optimization
│   └── test_cog_settings_benchmark.R
└── scripts/           # Production pipeline (*b.R)
    ├── 00b_extract_metadata_all.R
    ├── 01b_make_cog_all.R
    └── 02b_make_stac_all.R    # Auto-detects hosted vs local COGs
```

---

## Step 00: Metadata Extraction and Validation

Extract raster metadata once and validate core spatial assumptions.

### Spatial Assumptions

All WRI rasters are assumed to have:
- **CRS:** EPSG:5070 (Conus Albers Equal Area)
- **Resolution:** 90 × 90 meters
- **Fixed spatial extent:** Continental US bounds
- **Dimensions:** 52355 columns × 57865 rows

### Scripts

- **00a_extract_metadata_one.R** - Prototype: extract from one raster
- **00b_extract_metadata_all.R** - Production: extract from all rasters

### Outputs

- `config/all_layers_raw.csv` - All extracted metadata
- `config/all_layers_consistent.csv` - Rasters passing validation
- `config/all_layers_inconsistent.csv` - Rasters failing validation

---

## Step 01: COG Creation

Convert validated rasters into Cloud Optimized GeoTIFFs.

### What Makes a Good COG

1. **Internal tiling** - Data organized in 256×256 pixel chunks
2. **Compression** - LZW or DEFLATE to reduce file size
3. **Overviews (pyramids)** - 7 levels for multi-scale access
4. **HTTP range request support** - When hosted, allows partial downloads

### Scripts

- **01a_make_cog_one.R** - Prototype: convert one raster
- **01b_make_cog_all.R** - Production: convert all rasters with parallel processing

### Outputs

- `cogs/<filename>.tif` - Cloud Optimized GeoTIFFs

---

## Step 02: STAC Generation

Create a STAC Catalog with auto-detected hosted URLs.

### Purpose

Generate a STAC catalog that **automatically detects** which COGs are hosted on KNB and uses the appropriate URL for each:

- **Hosted files** → KNB URL (e.g., `https://knb.ecoinformatics.org/data/WRI_score.tif`)
- **Non-hosted files** → Local path (e.g., `../cogs/elevation.tif`)

This produces the STAC catalog used by the `fedex` R package. It works at any stage — before any uploads, after some, or after all files are hosted.

### Scripts

- **02a_make_stac_one.R** — Prototype: STAC for one layer (local path)
- **02b_make_stac_all.R** — Production: STAC for all layers (auto-detects hosting)

### How It Works

1. Checks each COG file individually via HTTP HEAD request to KNB
2. If file returns 200 status → uses KNB URL
3. If file returns 404 or timeout → uses local path
4. Adds `is_hosted: true/false` property to each STAC item for debugging

### Usage

```bash
# After running 00b and 01b (and optionally uploading COGs to KNB)
Rscript scripts/02b_make_stac_all.R
```

**Example output:**

```text
=== Checking which files are hosted on KNB ===
[1/82] Checking: WRI_score.tif ... ✓ HOSTED
[2/82] Checking: elevation.tif ... ✗ not hosted
...

=== Hosting Summary ===
  Total files:   82
  Hosted on KNB: 15
  Local only:    67
```

**Outputs:** `stac/` directory with mixed hrefs — copy to `fedex/inst/extdata/stac/` for package distribution.

### Typical Workflow

```bash
# 1. Upload files to KNB (manual, via DataONE portal or API)
#    Upload as you go - no need to wait for all files

# 2. Generate STAC catalog
Rscript scripts/02b_make_stac_all.R

# 3. Copy to fedex package
cp -r stac/* ../fedex/inst/extdata/stac/

# 4. Test in fedex
cd ../fedex
devtools::load_all()

# Try a hosted file
get_layer("WRI_score", bbox = c(-122, 37, -121, 38))  # Streams from KNB

# Try a non-hosted file
get_layer("elevation", bbox = c(-122, 37, -121, 38))  # Error with helpful message
```

### When to Rerun

- After uploading new COGs to KNB (updates hosted status)
- When URLs change or files are renamed
- Before releasing a new version of `fedex` package

---

## Access Assumptions

### HTTP Range Request Support

COG streaming requires servers to support **HTTP range requests** (HTTP 206 Partial Content).

**KNB Status:** ✅ Verified working
- Supports `Accept-Ranges: bytes`
- Returns `206 Partial Content` for byte ranges
- Allows efficient tile-by-tile access

**Verification:** See `fedex/demos/test_cog_streaming_verified.R`

### Authentication

**Current:** No authentication required for KNB public data

**Future:** If moving to authenticated storage:
- Update `fedex` to handle API tokens
- Add credential management in STAC config
- Update GDAL environment for authenticated `/vsicurl/` access

### File Naming Convention

STAC assumes COG filenames match the `cog_filename` column in `config/all_layers_consistent.csv`:

```
WRI_score.tif
aspect.tif
elevation.tif
slope.tif
...
```

**Important:** KNB URLs must use exact filenames from metadata CSV.

---

## Current Status

### Completed

- ✅ Metadata extraction (all 82 layers)
- ✅ COG creation (all 82 layers, 7 overview levels each)
- ✅ STAC with hybrid URL detection (02b)
- ✅ COG streaming verification from KNB

### In Progress

- 🔄 Uploading COGs to KNB (gradual process)
- 🔄 Testing fedex package with STAC catalog

### Planned

- 📋 Performance benchmarks (tile sizes, compression methods)
- 📋 Automated STAC validation (stac-validator)
- 📋 CI/CD for regenerating STAC when data updates

---

## Output Examples

### STAC Item (hosted file)

```json
{
  "assets": {
    "data": {
      "href": "https://knb.ecoinformatics.org/data/WRI_score.tif",
      "type": "image/tiff; application=geotiff; profile=cloud-optimized"
    }
  },
  "properties": { "is_hosted": true }
}
```

### STAC Item (non-hosted file)

```json
{
  "assets": {
    "data": {
      "href": "../../cogs/elevation.tif",
      "type": "image/tiff; application=geotiff; profile=cloud-optimized"
    }
  },
  "properties": { "is_hosted": false }
}
```

---

## Integration with `fedex` R Package

The `fedex` package uses the STAC catalog generated by step 02:

1. STAC generated here → `stac/` (via 02b_make_stac_all.R)
2. Copied to fedex → `fedex/inst/extdata/stac/`
3. Ships with package → Users access via `system.file()`
4. `get_layer()` reads STAC → Streams COG from KNB (if hosted) or shows helpful error (if not)

**Workflow:**
```r
# In fedex package
library(fedex)

# Hosted files stream from KNB
wri <- get_layer('WRI_score', bbox = c(-122, 37, -121, 38))
# → Reads STAC item → Detects is_hosted=TRUE → Streams tiles via HTTP ranges

# Non-hosted files show helpful error
elev <- get_layer('elevation', bbox = c(-122, 37, -121, 38))
# → Reads STAC item → Detects is_hosted=FALSE → Returns informative error message
```

---

## Best Practices

### When to Regenerate STAC

- ✅ After uploading new COGs to KNB
- ✅ When COG URLs change
- ✅ When metadata changes (extents, CRS, etc.)
- ❌ NOT when only analysis scripts change

### File Size Expectations

| File Type | Typical Size | Notes |
|-----------|--------------|-------|
| Raw GeoTIFF | 3-4 GB | Uncompressed, no overviews |
| COG | 3-4 GB | Compressed + overviews ≈ same size |
| STAC Item | 1-3 KB | JSON metadata only |
| Metadata CSV | 50-100 KB | All 82 layers |

### Quality Checks

Before uploading COGs to KNB:
1. ✅ Verify overviews exist: `gdalinfo cogs/WRI_score.tif | grep "Overviews"`
2. ✅ Check tiling: Should see `Block=256x256`
3. ✅ Test streaming: Run `fedex/demos/test_cog_streaming_verified.R`
4. ✅ Validate STAC: Use `stac-validator` (Python tool)

---

## Troubleshooting

### STAC URLs Don't Work

**Symptom:** `fedex::get_layer()` can't find file

**Check:**
1. Verify KNB URL in browser
2. Check filename matches metadata CSV exactly
3. Rerun `02b_make_stac_all.R` to refresh hosting status
4. Confirm STAC copied to `fedex/inst/extdata/stac/`

### COG Streaming Is Slow

**Symptom:** Small bbox downloads entire file

**Check:**
1. Verify overviews: `gdalinfo -checksum cogs/file.tif`
2. Test HTTP ranges: See `fedex/demos/` scripts
3. Check tiling: Should be 256×256 blocks
4. Confirm server supports range requests

### Metadata Extraction Fails

**Symptom:** Rasters in `inconsistent.csv`

**Check:**
1. Verify CRS is EPSG:5070
2. Check resolution is exactly 90×90 meters
3. Ensure extent matches reference extent
4. Look for corrupted or partial files

---

## References

- [Cloud Optimized GeoTIFF](https://www.cogeo.org/)
- [STAC Specification](https://stacspec.org/)
- [GDAL COG Driver](https://gdal.org/drivers/raster/cog.html)
- [KNB Data Repository](https://knb.ecoinformatics.org/)
- [fedex R Package](../fedex/) - Companion package for data access

---

## Summary

✅ **Pipeline is production-ready** for local development
✅ **COGs are properly optimized** (tiling + overviews)
✅ **STAC supports both local and hosted workflows**
🔄 **Scaling to full KNB hosting** requires uploading remaining files and flipping flag

**Next Steps:**

1. Continue uploading COGs to KNB (gradual process)
2. Rerun `02b_make_stac_all.R` periodically to update hosting status
3. Copy updated STAC to `fedex/inst/extdata/stac/`
4. Release `fedex` updates as more files become hosted
5. Eventually: All files hosted → Full remote COG streaming capability
