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
│              for the rest) → copy to firex package              │
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

This produces the STAC catalog used by the `firex` R package. It works at any stage — before any uploads, after some, or after all files are hosted.

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

**Outputs:** `stac/` directory with mixed hrefs — copy to `firex/inst/stac/` for package distribution.

### Typical Workflow

```bash
# 1. Upload files to KNB (manual, via DataONE portal or API)
#    Upload as you go - no need to wait for all files

# 2. Generate STAC catalog
Rscript scripts/02b_make_stac_all.R

# 3. Replace the STAC catalog in firex
rm -rf ../firex/inst/stac
cp -R stac ../firex/inst/stac

# 4. Test in firex
cd ../firex
devtools::load_all()

# Try a hosted file
get_layer("WRI_score", bbox = c(-122, 37, -121, 38))  # Streams from KNB

# Try a non-hosted file
get_layer("elevation", bbox = c(-122, 37, -121, 38))  # Error with helpful message
```

### When to Rerun

- After uploading new COGs to KNB (updates hosted status)
- When URLs change or files are renamed
- Before releasing a new version of `firex` package

---

## Access Assumptions

### HTTP Range Request Support

COG streaming requires servers to support **HTTP range requests** (HTTP 206 Partial Content).

**KNB Status:** ✅ Verified working
- Supports `Accept-Ranges: bytes`
- Returns `206 Partial Content` for byte ranges
- Allows efficient tile-by-tile access

**Verification:** See `firex/demos/test_cog_streaming_verified.R`

### Authentication

**Current:** No authentication required for KNB public data

**Future:** If moving to authenticated storage:
- Update `firex` to handle API tokens
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
- 🔄 Testing firex package with STAC catalog

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

## Integration with `firex` R Package

The `firex` package uses the STAC catalog generated by step 02:

1. STAC generated here → `stac/` (via 02b_make_stac_all.R)
2. Copied to firex → `firex/inst/stac/`
3. Ships with package → Users access via `system.file()`
4. `get_layer()` reads STAC → Streams COG from KNB (if hosted) or shows helpful error (if not)

**Workflow:**
```r
# In firex package
library(firex)

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
3. ✅ Test streaming: Run `firex/demos/test_cog_streaming_verified.R`
4. ✅ Validate STAC: Use `stac-validator` (Python tool)

---

## Troubleshooting

### STAC URLs Don't Work

**Symptom:** `firex::get_layer()` can't find file

**Check:**
1. Verify KNB URL in browser
2. Check filename matches metadata CSV exactly
3. Rerun `02b_make_stac_all.R` to refresh hosting status
4. Confirm STAC copied to `firex/inst/stac/`

### COG Streaming Is Slow

**Symptom:** Small bbox downloads entire file

**Check:**
1. Verify overviews: `gdalinfo -checksum cogs/file.tif`
2. Test HTTP ranges: See `firex/demos/` scripts
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
- [firex R Package](../firex/) - Companion package for data access

---

## Summary

✅ **Pipeline is production-ready** for local development
✅ **COGs are properly optimized** (tiling + overviews)
✅ **STAC supports both local and hosted workflows**
✅ **Scaling to full KNB hosting** 

## RAW DATA FILE STRUCTURE [DELETE IN FINAL VERSION]

```
├── air_quality
│   ├── air_quality_domain_score.tif
│   ├── air_quality_resilience.tif
│   ├── air_quality_resistance.tif
│   ├── air_quality_status.tif
│   ├── final_checks
│   │   ├── air_classification_merged.tif
│   │   ├── air_classified_alaska.tif
│   │   ├── air_classified_arizona.tif
│   │   ├── air_classified_british_columbia.tif
│   │   ├── air_classified_california.tif
│   │   ├── air_classified_colorado.tif
│   │   ├── air_classified_idaho.tif
│   │   ├── air_classified_montana.tif
│   │   ├── air_classified_nevada.tif
│   │   ├── air_classified_new_mexico.tif
│   │   ├── air_classified_oregon.tif
│   │   ├── air_classified_utah.tif
│   │   ├── air_classified_washington.tif
│   │   ├── air_classified_wyoming.tif
│   │   └── air_classified_yukon.tif
│   ├── indicators
│   │   ├── air_quality_resistance_asthma.tif
│   │   ├── air_quality_resistance_copd.tif
│   │   ├── air_quality_resistance_hospital_density.tif
│   │   ├── air_quality_resistance_vulnerable_populations.tif
│   │   ├── air_quality_resistance_vulnerable_workers.tif
│   │   ├── air_quality_status_aqi_100.tif
│   │   └── air_quality_status_aqi_300.tif
│   └── indicators_no_mask
│       ├── air_quality_resistance_asthma.tif
│       ├── air_quality_resistance_copd.tif
│       ├── air_quality_resistance_hospital_density.tif
│       ├── air_quality_resistance_vulnerable_populations.tif
│       ├── air_quality_resistance_vulnerable_workers.tif
│       ├── air_quality_status_aqi_100.tif
│       ├── air_quality_status_aqi_300.tif
│       └── archive
│           ├── air_quality_resistance_asthma.tif
│           ├── air_quality_resistance_copd.tif
│           ├── air_quality_resistance_vulnerable_populations.tif
│           └── air_quality_resistance_vulnerable_workers.tif
├── communities
│   ├── archive
│   │   ├── archive
│   │   │   ├── communities_recovery_greater_than_200k.tif
│   │   │   ├── communities_recovery_poverty.tif
│   │   │   └── communities_resistance_vol_fire_stations_test.tif
│   │   ├── communities_domain_score_unmasked.tif
│   │   ├── communities_recovery_unmasked.tif
│   │   ├── communities_resilience_unmasked.tif
│   │   ├── communities_resistance_unmasked.tif
│   │   ├── communities_status_unmasked.tif
│   │   └── final_layers_no_mask
│   │       ├── communities_domain_score.tif
│   │       ├── communities_recovery.tif
│   │       ├── communities_resilience.tif
│   │       └── communities_resistance.tif
│   ├── communities_domain_score.tif
│   ├── communities_recovery.tif
│   ├── communities_resilience.tif
│   ├── communities_resistance.tif
│   ├── final_checks
│   │   ├── communities_classification_merged.tif
│   │   ├── communities_classified_alaska.tif
│   │   ├── communities_classified_arizona.tif
│   │   ├── communities_classified_british_columbia.tif
│   │   ├── communities_classified_california.tif
│   │   ├── communities_classified_colorado.tif
│   │   ├── communities_classified_idaho.tif
│   │   ├── communities_classified_montana.tif
│   │   ├── communities_classified_nevada.tif
│   │   ├── communities_classified_new_mexico.tif
│   │   ├── communities_classified_oregon.tif
│   │   ├── communities_classified_utah.tif
│   │   ├── communities_classified_washington.tif
│   │   ├── communities_classified_wyoming.tif
│   │   ├── communities_classified_yukon.tif
│   │   ├── communities_dif.tif
│   │   └── communities_gaps_in_domain_score.tif
│   ├── indicators
│   │   ├── communities_recovery_income.tif
│   │   ├── communities_recovery_incorporation.tif
│   │   ├── communities_recovery_owners.tif
│   │   ├── communities_resistance_age_65_plus.tif
│   │   ├── communities_resistance_cwpps.tif
│   │   ├── communities_resistance_disability.tif
│   │   ├── communities_resistance_egress.tif
│   │   ├── communities_resistance_firewise_communities.tif
│   │   ├── communities_resistance_no_vehicle.tif
│   │   └── communities_resistance_volunteer_fire_stations.tif
│   └── indicators_no_mask
│       ├── archive
│       │   ├── communities_recovery_income.tif
│       │   ├── communities_recovery_owners.tif
│       │   ├── communities_resistance_age_65_plus.tif
│       │   ├── communities_resistance_disability.tif
│       │   ├── communities_resistance_firewise_communities.tif
│       │   ├── communities_resistance_no_vehicle.tif
│       │   └── communities_resistance_volunteer_fire_stations.tif
│       ├── communities_recovery_income.tif
│       ├── communities_recovery_incorporation.tif
│       ├── communities_recovery_owners.tif
│       ├── communities_resistance_age_65_plus.tif
│       ├── communities_resistance_cwpps.tif
│       ├── communities_resistance_disability.tif
│       ├── communities_resistance_egress.tif
│       ├── communities_resistance_firewise_communities.tif
│       ├── communities_resistance_no_vehicle.tif
│       └── communities_resistance_volunteer_fire_stations.tif
├── ds.json
├── infrastructure
│   ├── final_checks
│   │   ├── infrastructure_classification_merged.tif
│   │   ├── infrastructure_classified_alaska.tif
│   │   ├── infrastructure_classified_arizona.tif
│   │   ├── infrastructure_classified_british_columbia.tif
│   │   ├── infrastructure_classified_california.tif
│   │   ├── infrastructure_classified_colorado.tif
│   │   ├── infrastructure_classified_idaho.tif
│   │   ├── infrastructure_classified_montana.tif
│   │   ├── infrastructure_classified_nevada.tif
│   │   ├── infrastructure_classified_new_mexico.tif
│   │   ├── infrastructure_classified_oregon.tif
│   │   ├── infrastructure_classified_utah.tif
│   │   ├── infrastructure_classified_washington.tif
│   │   ├── infrastructure_classified_wyoming.tif
│   │   └── infrastructure_classified_yukon.tif
│   ├── indicators
│   │   ├── infrastructure_resistance_building_codes.tif
│   │   ├── infrastructure_resistance_d_space.tif
│   │   ├── infrastructure_resistance_egress.tif
│   │   ├── infrastructure_resistance_fire_resource_density.tif
│   │   ├── infrastructure_resistance_wildland_urban_interface_test.tif
│   │   └── infrastructure_resistance_wildland_urban_interface.tif
│   ├── indicators_no_mask
│   │   ├── infrastructure_resistance_building_codes.tif
│   │   ├── infrastructure_resistance_d_space.tif
│   │   ├── infrastructure_resistance_egress.tif
│   │   ├── infrastructure_resistance_fire_resource_density.tif
│   │   ├── infrastructure_resistance_wildland_urban_interface_test.tif
│   │   └── infrastructure_resistance_wildland_urban_interface.tif
│   ├── infrastructure_domain_score.tif
│   ├── infrastructure_recovery.tif
│   ├── infrastructure_resilience.tif
│   ├── infrastructure_resistance.tif
│   └── infrastructure_status.tif
├── livelihoods
│   ├── archive
│   │   └── final_layers_no_mask
│   │       ├── livelihoods_domain_score.tif
│   │       ├── livelihoods_recovery.tif
│   │       ├── livelihoods_resilience.tif
│   │       ├── livelihoods_resistance.tif
│   │       └── livelihoods_status.tif
│   ├── final_checks
│   │   ├── livelihoods_classification_merged.tif
│   │   ├── livelihoods_classified_alaska.tif
│   │   ├── livelihoods_classified_arizona.tif
│   │   ├── livelihoods_classified_british_columbia.tif
│   │   ├── livelihoods_classified_california.tif
│   │   ├── livelihoods_classified_colorado.tif
│   │   ├── livelihoods_classified_idaho.tif
│   │   ├── livelihoods_classified_montana.tif
│   │   ├── livelihoods_classified_nevada.tif
│   │   ├── livelihoods_classified_new_mexico.tif
│   │   ├── livelihoods_classified_oregon.tif
│   │   ├── livelihoods_classified_utah.tif
│   │   ├── livelihoods_classified_washington.tif
│   │   ├── livelihoods_classified_wyoming.tif
│   │   └── livelihoods_classified_yukon.tif
│   ├── indicators
│   │   ├── livelihoods_recovery_diversity_of_jobs.tif
│   │   ├── livelihoods_resistance_job_vulnerability.tif
│   │   ├── livelihoods_status_housing_burden.tif
│   │   ├── livelihoods_status_median_income.tif
│   │   └── livelihoods_status_unemployment.tif
│   ├── indicators_no_mask
│   │   ├── archive
│   │   │   ├── livelihoods_recovery_diversity_of_jobs.tif
│   │   │   ├── livelihoods_resistance_job_vulnerability.tif
│   │   │   ├── livelihoods_status_housing_burden.tif
│   │   │   ├── livelihoods_status_median_income.tif
│   │   │   └── livelihoods_status_unemployment.tif
│   │   ├── livelihoods_recovery_diversity_of_jobs.tif
│   │   ├── livelihoods_resistance_job_vulnerability.tif
│   │   ├── livelihoods_status_housing_burden.tif
│   │   ├── livelihoods_status_median_income.tif
│   │   └── livelihoods_status_unemployment.tif
│   ├── livelihoods_domain_score.tif
│   ├── livelihoods_recovery.tif
│   ├── livelihoods_resilience.tif
│   ├── livelihoods_resistance.tif
│   ├── livelihoods_status.tif
│   └── retro_2005
│       ├── indicators
│       │   └── livelihoods_status_housing_burden.tif
│       └── indicators_no_mask
│           └── livelihoods_status_housing_burden.tif
├── natural_habitats
│   ├── final_checks
│   │   ├── natural_habitats_classified_alaska.tif
│   │   ├── natural_habitats_classified_arizona.tif
│   │   ├── natural_habitats_classified_british_columbia.tif
│   │   ├── natural_habitats_classified_california.tif
│   │   ├── natural_habitats_classified_colorado.tif
│   │   ├── natural_habitats_classified_idaho.tif
│   │   ├── natural_habitats_classified_merged.tif
│   │   ├── natural_habitats_classified_montana.tif
│   │   ├── natural_habitats_classified_nevada.tif
│   │   ├── natural_habitats_classified_new_mexico.tif
│   │   ├── natural_habitats_classified_oregon.tif
│   │   ├── natural_habitats_classified_utah.tif
│   │   ├── natural_habitats_classified_washington.tif
│   │   ├── natural_habitats_classified_wyoming.tif
│   │   └── natural_habitats_classified_yukon.tif
│   ├── indicators_mask
│   │   ├── natural_habitats_recovery_diversity.tif
│   │   ├── natural_habitats_recovery_ppt.tif
│   │   ├── natural_habitats_recovery_tree_traits.tif
│   │   ├── natural_habitats_resistance_density.tif
│   │   ├── natural_habitats_resistance_NDVI.tif
│   │   ├── natural_habitats_resistance_npp.tif
│   │   ├── natural_habitats_resistance_tree_traits.tif
│   │   ├── natural_habitats_resistance_vpd.tif
│   │   ├── natural_habitats_status_extent_change_2005.tif
│   │   └── natural_habitats_status_percent_protected.tif
│   ├── indicators_no_mask
│   │   ├── natural_habitats_recovery_diversity.tif
│   │   ├── natural_habitats_recovery_ppt.tif
│   │   ├── natural_habitats_recovery_tree_traits.tif
│   │   ├── natural_habitats_resistance_density.tif
│   │   ├── natural_habitats_resistance_NDVI.tif
│   │   ├── natural_habitats_resistance_npp.tif
│   │   ├── natural_habitats_resistance_tree_traits.tif
│   │   ├── natural_habitats_resistance_vpd.tif
│   │   ├── natural_habitats_status_extent_change_2005.tif
│   │   └── natural_habitats_status_percent_protected.tif
│   ├── natural_habitats_domain_score.tif
│   ├── natural_habitats_recovery.tif
│   ├── natural_habitats_resilience.tif
│   ├── natural_habitats_resistance.tif
│   └── natural_habitats_status.tif
├── sense_of_place
│   ├── archive
│   │   └── iconic_species_old
│   │       ├── final_checks
│   │       │   ├── species_classified_alaska.tif
│   │       │   ├── species_classified_arizona.tif
│   │       │   ├── species_classified_british_columbia.tif
│   │       │   ├── species_classified_california.tif
│   │       │   ├── species_classified_colorado.tif
│   │       │   ├── species_classified_idaho.tif
│   │       │   ├── species_classified_merged.tif
│   │       │   ├── species_classified_montana.tif
│   │       │   ├── species_classified_nevada.tif
│   │       │   ├── species_classified_new_mexico.tif
│   │       │   ├── species_classified_oregon.tif
│   │       │   ├── species_classified_utah.tif
│   │       │   ├── species_classified_washington.tif
│   │       │   ├── species_classified_wyoming.tif
│   │       │   └── species_classified_yukon.tif
│   │       ├── sense_of_place_iconic_species_domain_score.tif
│   │       ├── sense_of_place_iconic_species_recovery.tif
│   │       ├── sense_of_place_iconic_species_resilience.tif
│   │       ├── sense_of_place_iconic_species_resistance.tif
│   │       └── sense_of_place_iconic_species_status.tif
│   ├── iconic_places
│   │   ├── final_checks
│   │   │   ├── places_classification_merged.tif
│   │   │   ├── places_classified_alaska.tif
│   │   │   ├── places_classified_arizona.tif
│   │   │   ├── places_classified_british_columbia.tif
│   │   │   ├── places_classified_california.tif
│   │   │   ├── places_classified_colorado.tif
│   │   │   ├── places_classified_idaho.tif
│   │   │   ├── places_classified_montana.tif
│   │   │   ├── places_classified_nevada.tif
│   │   │   ├── places_classified_new_mexico.tif
│   │   │   ├── places_classified_oregon.tif
│   │   │   ├── places_classified_utah.tif
│   │   │   ├── places_classified_washington.tif
│   │   │   ├── places_classified_wyoming.tif
│   │   │   └── places_classified_yukon.tif
│   │   ├── indicators
│   │   │   ├── sense_of_place_iconic_places_recovery_degree_of_protection.tif
│   │   │   ├── sense_of_place_iconic_places_recovery_national_parks.tif
│   │   │   ├── sense_of_place_iconic_places_resistance_egress.tif
│   │   │   ├── sense_of_place_iconic_places_resistance_fire_resource_density.tif
│   │   │   ├── sense_of_place_iconic_places_resistance_national_parks.tif
│   │   │   ├── sense_of_place_iconic_places_resistance_structures.tif
│   │   │   ├── sense_of_place_iconic_places_resistance_wui.tif
│   │   │   └── sense_of_place_iconic_places_status_presence.tif
│   │   ├── sense_of_place_iconic_places_domain_score.tif
│   │   ├── sense_of_place_iconic_places_recovery.tif
│   │   ├── sense_of_place_iconic_places_resilience.tif
│   │   └── sense_of_place_iconic_places_resistance.tif
│   └── iconic_species
│       ├── final_checks
│       │   ├── species_classification_merged.tif
│       │   ├── species_classified_alaska.tif
│       │   ├── species_classified_arizona.tif
│       │   ├── species_classified_british_columbia.tif
│       │   ├── species_classified_california.tif
│       │   ├── species_classified_colorado.tif
│       │   ├── species_classified_idaho.tif
│       │   ├── species_classified_montana.tif
│       │   ├── species_classified_nevada.tif
│       │   ├── species_classified_new_mexico.tif
│       │   ├── species_classified_oregon.tif
│       │   ├── species_classified_utah.tif
│       │   ├── species_classified_washington.tif
│       │   ├── species_classified_wyoming.tif
│       │   └── species_classified_yukon.tif
│       ├── indicators
│       │   ├── sense_of_place_iconic_species_area_recovery.tif
│       │   ├── sense_of_place_iconic_species_status_75_extinction_rescaled.tif
│       │   ├── sense_of_place_iconic_species_traits_recovery.tif
│       │   └── sense_of_place_iconic_species_traits_resistance.tif
│       ├── sense_of_place_iconic_species_domain_score.tif
│       ├── sense_of_place_iconic_species_recovery.tif
│       ├── sense_of_place_iconic_species_resilience.tif
│       ├── sense_of_place_iconic_species_resistance.tif
│       └── sense_of_place_iconic_species_status.tif
├── species
│   ├── final_checks
│   │   ├── species_classification_merged.tif
│   │   ├── species_classified_alaska.tif
│   │   ├── species_classified_arizona.tif
│   │   ├── species_classified_british_columbia.tif
│   │   ├── species_classified_california.tif
│   │   ├── species_classified_colorado.tif
│   │   ├── species_classified_idaho.tif
│   │   ├── species_classified_montana.tif
│   │   ├── species_classified_nevada.tif
│   │   ├── species_classified_new_mexico.tif
│   │   ├── species_classified_oregon.tif
│   │   ├── species_classified_utah.tif
│   │   ├── species_classified_washington.tif
│   │   ├── species_classified_wyoming.tif
│   │   ├── species_classified_yukon.tif
│   │   ├── species_dif.tif
│   │   └── species_gaps_in_domain_score.tif
│   ├── indicators
│   │   ├── species_recovery_range_area.tif
│   │   ├── species_recovery_traits.tif
│   │   └── species_resistance_traits.tif
│   ├── species_domain_score.tif
│   ├── species_recovery.tif
│   ├── species_resilience.tif
│   ├── species_resistance.tif
│   └── species_status.tif
├── water
│   ├── final_checks
│   │   ├── water_classification_merged.tif
│   │   ├── water_classified_alaska.tif
│   │   ├── water_classified_arizona.tif
│   │   ├── water_classified_british_columbia.tif
│   │   ├── water_classified_california.tif
│   │   ├── water_classified_colorado.tif
│   │   ├── water_classified_idaho.tif
│   │   ├── water_classified_montana.tif
│   │   ├── water_classified_nevada.tif
│   │   ├── water_classified_new_mexico.tif
│   │   ├── water_classified_oregon.tif
│   │   ├── water_classified_utah.tif
│   │   ├── water_classified_washington.tif
│   │   ├── water_classified_wyoming.tif
│   │   ├── water_classified_yukon.tif
│   │   └── water_gaps_in_domain_score.tif
│   ├── indicators
│   │   ├── archive
│   │   │   ├── drought_plan_scores.tif
│   │   │   ├── streamflow_status_scores_2024_old.tif
│   │   │   ├── streamflow_status_scores_2024.tif
│   │   │   ├── water_resistance_water_treatment_masked.tif
│   │   │   ├── water_resistance_water_treatment.tif
│   │   │   ├── water_status_surface_water_gf_test.tif
│   │   │   ├── water_status_surface_water_gf.tif
│   │   │   ├── water_status_surface_water_quantity.tif
│   │   │   ├── water_status_surface_water.tif
│   │   │   ├── water_status_surface_water_timing.tif
│   │   │   └── water_treatment_scores_2024.tif
│   │   ├── water_resistance_drought_plans.tif
│   │   ├── water_resistance_water_treatment.tif
│   │   ├── water_status_surface_water_quantity.tif
│   │   └── water_status_surface_water_timing.tif
│   ├── water_domain_score.tif
│   ├── water_resilience.tif
│   ├── water_resistance.tif
│   ├── water_status-old.tif
│   └── water_status.tif
└── WRI_score.tif
```