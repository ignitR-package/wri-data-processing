# Wildfire Resilience Index (WRI) Data Processing

This repository contains the data processing pipeline for converting the Wildfire Resilience Index (WRI) dataset into a cloud-accessible format. The pipeline transforms raw GeoTIFF layers into Cloud-Optimized GeoTIFFs (COGs) with STAC metadata for discovery and access.

## Project Overview

The WRI measures wildfire resilience across California using eight domains: Infrastructure, Communities, Livelihoods, Sense of Place, Species, Habitats, Water, and Air. The dataset includes nearly 100 high-resolution geospatial layers totaling approximately 250 GB.

This processing pipeline prepares the data for public access through an R package by:

1. **Extracting metadata** from all raw GeoTIFF layers
2. **Converting to COGs** with appropriate compression and tiling
3. **Creating STAC catalogs** for standardized data discovery

### Team

**ignitR** — MEDS Capstone Project, UC Santa Barbara Bren School

- Emily Miller
- Ixel Medrano
- Kaiju Morquecho
- Hylaea Miller

**Faculty Advisor:** Max Czapanskiy  
**Client:** Dr. Caitlin Fong, NCEAS

## Repository Structure

```
wildfire-resilience-index/
│
├── README.md                 # This file
│
├── scripts/                  # Production pipeline
│   ├── README.md             # Workflow documentation
│   ├── R/
│   │   └── utils.R           # Shared helper functions
│   ├── 00_extract_metadata.R # Extract metadata from all layers
│   ├── 01_make_cog.R         # Convert all layers to COGs
│   └── 02_make_stac.R        # Create STAC catalog
│
├── scratch/                  # Development & testing
│   ├── README.md             # Prototype script notes
│   ├── 00_extract_metadata.R # Single-layer metadata test
│   ├── 01_make_cog.R         # Single-layer COG test
│   └── 02_make_stac.R        # Single-layer STAC test
│
├── config/                   # Generated metadata (gitignored)
│   ├── all_layers_metadata.csv
│   ├── indicator_layers.csv
│   ├── aggregate_layers.csv
│   └── ...
│
├── cogs/                     # Generated COGs (gitignored)
│
├── stac/                     # Generated STAC catalog (gitignored)
│
├── outputs/                  # Validation reports (gitignored)
│
└── data/                     # Raw WRI data (not in repo)
```

## Quick Start

### Prerequisites

- **R 4.x** with packages: `terra`, `sf`, `dplyr`, `readr`, `fs`, `jsonlite`, `glue`
- **GDAL 3.x** with COG driver support (for `gdal_translate`)

### Running the Pipeline

The pipeline runs in three sequential steps:

```r
# Step 1: Extract metadata from all raw layers
source("scripts/00_extract_metadata.R")

# Step 2: Convert consistent layers to COGs
source("scripts/01_make_cog.R")

# Step 3: Create STAC catalog
source("scripts/02_make_stac.R")
```

Each script is safe to re-run — it will skip already-processed files.

### Testing on Single Files

Use the scripts in `scratch/` to test the pipeline on individual files:

```r
# Test metadata extraction
source("scratch/00_extract_metadata.R")

# Test COG conversion
source("scratch/01_make_cog.R")

# Test STAC creation
source("scratch/02_make_stac.R")
```

See the [scratch README](scratch/README.md) for details.

## Data Flow

```
Raw GeoTIFFs (data/)
        │
        ▼
┌───────────────────────────┐
│ 00_extract_metadata.R     │
│ - Scan all .tif files     │
│ - Extract raster metadata │
│ - Classify by type/domain │
│ - Check consistency       │
└───────────────────────────┘
        │
        ▼
    config/all_layers_metadata.csv
        │
        ▼
┌───────────────────────────┐
│ 01_make_cog.R             │
│ - Read metadata inventory │
│ - Convert each to COG     │
│ - Choose resampling method│
│ - Log conversion results  │
└───────────────────────────┘
        │
        ▼
    cogs/<data_type>/<domain>/*.tif
        │
        ▼
┌───────────────────────────┐
│ 02_make_stac.R            │
│ - Read conversion log     │
│ - Extract spatial extents │
│ - Create STAC items       │
│ - Build catalog/collection│
└───────────────────────────┘
        │
        ▼
    stac/catalog.json
    stac/collections/wri_ignitR/
```

## Output Formats

### Cloud-Optimized GeoTIFFs (COGs)

COGs are GeoTIFFs organized for efficient cloud access:

- **Tiling:** 512×512 pixel blocks
- **Compression:** DEFLATE (lossless)
- **Overviews:** Internal pyramids for multi-resolution access
- **Resampling:** AVERAGE for continuous data, NEAREST for categorical

### STAC Catalog

The STAC catalog provides standardized metadata:

- **Catalog:** Root entry point
- **Collection:** Groups all WRI layers with shared extent
- **Items:** One per COG with bounding box, properties, and asset links

## Key Files

| File | Description |
|------|-------------|
| `scripts/R/utils.R` | Shared functions used across all scripts |
| `config/all_layers_metadata.csv` | Clean inventory of all consistent layers |
| `config/inconsistent_files_metadata.csv` | Layers with resolution/CRS/extent issues |
| `outputs/validation_reports/cog_conversion_log.csv` | Status of each COG conversion |

## License

Data processing code is open source. The WRI dataset license will be determined upon publication of the underlying research paper.

## Acknowledgments

- Dr. Caitlin Fong and NCEAS for providing the WRI dataset
- UC Santa Barbara Bren School of Environmental Science & Management
- MEDS program faculty and staff