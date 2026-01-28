# WRI Data Processing Pipeline

This repository contains a staged, reproducible pipeline for preparing Wildfire Resilience Index (WRI) raster data for downstream use. The pipeline extracts and validates metadata, converts rasters to Cloud Optimized GeoTIFFs (COGs), and generates STAC metadata for discovery and access.

The workflow is intentionally split into small, explicit steps. Expensive operations (reading large rasters) happen once, and all later steps rely on saved metadata.

---

## High-level workflow

Raw GeoTIFFs  
→ Metadata extraction + validation (00a / 00b)  
→ Metadata CSVs (source of truth)  
→ COG creation (01a / 01b)  
→ COGs  
→ STAC generation (02a / 02b)

---

## Design principles

- Single source of truth via metadata CSVs  
- Explicit spatial assumptions enforced once  
- Prototype (`a`) scripts mirrored by scaled (`b`) scripts  
- Rerun-safe, non-interactive execution  

---

## Directory structure

data/  
config/  
cogs/  
scripts/  
scratch/  
scratch_output/

---

## Step 00: Metadata extraction and validation

Extract raster metadata once and validate core spatial assumptions.

Assumptions:
- CRS: EPSG:5070  
- Resolution: 90 × 90 meters  
- Fixed spatial extent  

Outputs:
- config/all_layers_raw.csv  
- config/all_layers_consistent.csv  
- config/all_layers_inconsistent.csv  

---

## Step 01: COG creation

Convert validated rasters into Cloud Optimized GeoTIFFs.

- Uses metadata CSV to select inputs  
- No re-extraction of raster metadata  
- Multithreaded GDAL execution  

Outputs:
- cogs/<filename>.tif  

---

## Step 02: STAC generation

Create minimal STAC Catalog, Collection, and Item records.

- Metadata-driven (no raster I/O)  
- Extents reprojected from EPSG:5070 to EPSG:4326  
- STAC Items link directly to COG assets  

---

## Current status

- Metadata extraction: implemented  
- COG creation: implemented  
- STAC prototype: implemented  
- Optimization experiments: planned  

