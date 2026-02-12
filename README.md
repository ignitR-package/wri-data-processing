# Wildfire Resilience Index (WRI) Data Processing

This repository contains the data processing pipeline for converting the Wildfire Resilience Index (WRI) dataset into a cloud-accessible format. The pipeline transforms raw GeoTIFF layers into Cloud-Optimized GeoTIFFs (COGs) with STAC metadata for discovery and access.

The workflow is intentionally split into small, explicit steps. Expensive operations (reading large rasters) happen once, and all later steps rely on saved metadata.

---

## High-level Workflow

```
Raw GeoTIFFs
→ Metadata extraction + validation (00a / 00b)
→ Metadata CSVs (source of truth)
→ COG creation (01a / 01b)
→ COGs
→ STAC generation (02a / 02b / 02c)
→ Upload to KNB (when ready)
→ STAC with hosted URLs
```

---

## Design Principles

- **Single source of truth** via metadata CSVs
- **Explicit spatial assumptions** enforced once
- **Prototype (`a`) scripts** mirrored by **scaled (`b`) scripts**
- **Rerun-safe**, non-interactive execution
- **Local development** with path to **hosted production**

---

## Directory Structure

```
wri-data-processing/
├── data/              # Raw input GeoTIFFs
├── config/            # Metadata CSVs (source of truth)
├── cogs/              # Output Cloud Optimized GeoTIFFs
├── stac/              # STAC catalog (local file paths - for development)
├── scratch_output/
│   └── stac_hosted/   # STAC catalog (KNB URLs - for production)
├── prototypes/        # Single-file test scripts (*a.R)
│   └── 02c_make_stac_one_hosted.R  # Hosted URL STAC prototype
└── scripts/           # Batch processing scripts (*b.R)
    ├── 00b_extract_metadata_all.R
    ├── 01b_make_cog_all.R
    └── 02b_make_stac_all.R  # Has use_knb_urls flag
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

Create minimal STAC Catalog, Collection, and Item records for data discovery.

### Local vs Hosted Workflows

#### Local Development (Default)

For testing and development, STAC items point to **local file paths**:

```r
# scripts/02b_make_stac_all.R (default)
use_knb_urls <- FALSE
```

**Outputs:** `stac/` directory with relative file paths

**Use case:** Package development, local testing, debugging

#### Hosted Production (KNB)

For production deployment, STAC items point to **KNB URLs**:

```r
# scripts/02b_make_stac_all.R (set to TRUE)
use_knb_urls <- TRUE
knb_base_url <- "https://knb.ecoinformatics.org/data/"
```

**Outputs:** `scratch_output/stac_hosted/` directory with KNB URLs

**Use case:** After uploading COGs to KNB, generate STAC for the `fedex` R package

### Scripts

- **02a_make_stac_one.R** - Prototype: local file STAC for one layer
- **02c_make_stac_one_hosted.R** - Prototype: KNB URL STAC for one layer (WRI_score)
- **02b_make_stac_all.R** - Production: all layers with `use_knb_urls` flag

### Single Hosted File - Testing Workflow

Currently only **WRI_score.tif** is hosted on KNB. To generate its STAC:

```bash
# Generate single-item STAC with KNB URL
Rscript prototypes/02c_make_stac_one_hosted.R
```

This creates `scratch_output/stac_hosted/` with:
- Catalog, Collection, and Item (WRI_score.json only)
- Asset URL: `https://knb.ecoinformatics.org/data/WRI_score.tif`

**Purpose:** Used by `fedex` package during development for testing COG streaming from KNB.

### Scaling to All Hosted Files

When all COGs are uploaded to KNB:

1. **Upload all COGs to KNB** and note their URLs
2. **Verify filenames match** metadata CSV (e.g., `WRI_score.tif`, `aspect.tif`)
3. **Edit** `scripts/02b_make_stac_all.R`:
   ```r
   use_knb_urls <- TRUE  # Change from FALSE
   ```
4. **Run batch STAC generation:**
   ```bash
   Rscript scripts/02b_make_stac_all.R
   ```
5. **Copy to fedex package:**
   ```bash
   cp -r scratch_output/stac_hosted/* /path/to/fedex/inst/extdata/stac/
   ```
6. **Update fedex and release new version**

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
- ✅ STAC prototype (local paths)
- ✅ Single hosted STAC (WRI_score only)
- ✅ Batch STAC with hosted URL flag
- ✅ COG streaming verification from KNB

### In Progress

- 🔄 Uploading remaining 81 COGs to KNB
- 🔄 Generating full hosted STAC catalog

### Planned

- 📋 Performance benchmarks (tile sizes, compression methods)
- 📋 Automated STAC validation (stac-validator)
- 📋 CI/CD for regenerating STAC when data updates

---

## Output Examples

### Local STAC (Development)

```json
{
  "assets": {
    "data": {
      "href": "../../cogs/WRI_score.tif",
      "type": "image/tiff; application=geotiff; profile=cloud-optimized"
    }
  }
}
```

### Hosted STAC (Production)

```json
{
  "assets": {
    "data": {
      "href": "https://knb.ecoinformatics.org/data/WRI_score.tif",
      "type": "image/tiff; application=geotiff; profile=cloud-optimized"
    }
  }
}
```

---

## Integration with `fedex` R Package

The `fedex` package uses the **hosted STAC** catalog:

1. STAC generated here → `scratch_output/stac_hosted/`
2. Copied to fedex → `fedex/inst/extdata/stac/`
3. Ships with package → Users access via `system.file()`
4. `get_layer()` reads STAC → Streams COG from KNB

**Workflow:**
```r
# In fedex package
library(fedex)
wri <- get_layer('WRI_score', bbox = c(-122, 37, -121, 38))
# → Reads STAC item → Gets KNB URL → Streams tiles via HTTP ranges
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
3. Ensure `use_knb_urls = TRUE` when generating STAC
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
1. Upload all 82 COGs to KNB
2. Set `use_knb_urls = TRUE` in `02b_make_stac_all.R`
3. Run batch STAC generation
4. Copy to `fedex/inst/extdata/stac/`
5. Release `fedex` v1.0 with full hosted STAC
