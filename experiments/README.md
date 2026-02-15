# Experiments

This directory contains scripts for performance testing, benchmarking, and optimization. These are **not part of the main data processing pipeline** but are used to inform decisions about settings and configurations.

## Purpose

- Test different COG compression algorithms and settings
- Benchmark file sizes and processing times
- Compare resampling methods for overviews
- Evaluate trade-offs between file size and access speed

## Scripts

### `test_cog_settings_benchmark.R`

Tests multiple COG creation settings on a single file to compare performance.

**What it does:**
- Takes one input GeoTIFF
- Creates multiple COG versions with different settings:
  - Compression: DEFLATE, ZSTD, LZW
  - Predictor: 2, 3
  - Block size: 256, 512
  - BigTIFF: IF_SAFER, YES
  - Resampling: NEAREST, AVERAGE
- Outputs all COGs to `scratch_output/cogs/`
- Generates a comparison CSV with file sizes and settings

**When to use:**
- Before deciding on production COG settings
- When evaluating new compression algorithms
- To test settings on specific problematic files

**Example:**
```r
# Edit the input file in the script
meta_csv <- "scratch_output/livelihoods_domain_score_metadata.csv"

# Run the benchmark
source("experiments/test_cog_settings_benchmark.R")

# Compare results in the output CSV
readr::read_csv("scratch_output/cogs_comparison.csv")
```

## Relationship to Main Pipeline

| Directory | Purpose | Part of Pipeline? |
|-----------|---------|-------------------|
| `prototypes/` | Test workflow on single files | ✅ Yes (step `a`) |
| `scripts/` | Batch processing of all files | ✅ Yes (step `b`) |
| `experiments/` | Optimize settings, compare approaches | ❌ No (R&D only) |

## Notes

- Experiments write to `scratch_output/` to avoid polluting production directories
- Results inform decisions in the production scripts but are not automatically integrated
- These scripts may be less polished than production pipeline scripts
- Safe to run repeatedly - designed for iteration and exploration
