#!/usr/bin/env python3
"""
Add ProductionForecast scope disclaimers to all documentation files.
This script adds a critical warning section to markdown files that haven't been updated yet.
"""

import os
import glob
from pathlib import Path

# Base directory
BASE_DIR = Path(__file__).parent

# Files to skip (already updated manually or should not be modified)
SKIP_FILES = {
    "ACTUAL_DEPENDENCIES.md",
    "UPDATE_PLAN.md",
    "DOCUMENTATION_INDEX.md",
    "PROJECT_SUMMARY.md",
    "DOCUMENTATION_MAP.md",  # notes/DOCUMENTATION_MAP.md
    "part_1_core_infrastructure_services.md",
    "part_2_cdc_workers_communication.md",
    "part_3_docker_deployment_network.md",
    "part_1_web_api_layer.md",
}

# Disclaimer text templates
DISCLAIMER_INFRASTRUCTURE = """
## ⚠️ CRITICAL - ProductionForecast Service Scope

**ProductionForecast uses ONLY:**
- ✅ IMemoryCache (local in-memory cache)
- ✅ Electric.Core for CDC (Change Data Capture ONLY - table change tracking)
- ✅ Entity Framework Core

**ProductionForecast does NOT use:**
- ❌ Redis distributed caching
- ❌ Apache Pulsar messaging
- ❌ Electric.Core messaging/Pulsar features

**This document describes SHARED INFRASTRUCTURE.**
Other services (NotificationService) may use Redis/Pulsar.

---
"""

DISCLAIMER_PRODUCTION_FORECAST = """
## ⚠️ CRITICAL - ProductionForecast Caching & Messaging

**ProductionForecast uses:**
- ✅ IMemoryCache (local in-memory cache ONLY)
- ✅ OutputCache middleware (ASP.NET Core)
- ✅ Electric.Core for CDC (Change Data Capture - cache invalidation trigger)

**ProductionForecast does NOT use:**
- ❌ Redis (no distributed cache)
- ❌ Apache Pulsar (no messaging)
- ❌ DistributedDataManager
- ❌ Electric.Core Pulsar features

---
"""

DISCLAIMER_DOCS = """
## ⚠️ CRITICAL - ProductionForecast Service Scope

**This document may describe infrastructure capabilities (Redis, Pulsar, etc.).**

**ProductionForecast ACTUALLY uses ONLY:**
- ✅ IMemoryCache (local in-memory cache)
- ✅ Electric.Core for CDC (Change Data Capture ONLY)
- ✅ Entity Framework Core

**ProductionForecast does NOT use:**
- ❌ Redis
- ❌ Apache Pulsar
- ❌ Distributed caching
- ❌ Message bus

Other services (NotificationService) may use these technologies.

---
"""

def should_skip_file(filepath: Path) -> bool:
    """Check if file should be skipped."""
    return filepath.name in SKIP_FILES

def get_disclaimer_for_file(filepath: Path) -> str:
    """Get appropriate disclaimer based on file location."""
    path_str = str(filepath)

    if "production_forecast" in path_str:
        return DISCLAIMER_PRODUCTION_FORECAST
    elif "infrastructure" in path_str or "level_1" in path_str:
        return DISCLAIMER_INFRASTRUCTURE
    elif path_str.startswith(str(BASE_DIR / "docs")):
        return DISCLAIMER_DOCS
    else:
        return DISCLAIMER_INFRASTRUCTURE  # Default

def add_disclaimer_to_file(filepath: Path):
    """Add disclaimer to a markdown file if not already present."""

    # Skip if already updated
    if should_skip_file(filepath):
        print(f"[SKIP] {filepath.name} (already updated)")
        return False

    # Read file
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()
    except Exception as e:
        print(f"❌ Error reading {filepath}: {e}")
        return False

    # Skip if disclaimer already present
    if "CRITICAL - ProductionForecast" in content:
        print(f"[SKIP] {filepath.name} (disclaimer already present)")
        return False

    # Find where to insert disclaimer (after first heading block)
    lines = content.split('\n')
    insert_line = 0

    # Skip BOM, initial comments, and title
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith('# '):
            # Found main title, find next --- or ## or blank line section
            for j in range(i + 1, len(lines)):
                if lines[j].strip() == '---':
                    insert_line = j + 1
                    break
                elif lines[j].strip().startswith('## ') and not lines[j].strip().startswith('## ⚠️'):
                    insert_line = j
                    break
            break

    if insert_line == 0:
        print(f"[WARN] Could not find insertion point in {filepath.name}")
        return False

    # Insert disclaimer
    disclaimer = get_disclaimer_for_file(filepath)
    lines.insert(insert_line, disclaimer)
    new_content = '\n'.join(lines)

    # Write file
    try:
        with open(filepath, 'w', encoding='utf-8') as f:
            f.write(new_content)
        print(f"[OK] Updated {filepath.name}")
        return True
    except Exception as e:
        print(f"[ERROR] Error writing {filepath}: {e}")
        return False

def main():
    """Main execution."""
    print("=" * 60)
    print("ProductionForecast Documentation Disclaimer Insertion")
    print("=" * 60)
    print()

    # Find all markdown files
    md_files = []
    for pattern in ['docs/**/*.md', 'notes/**/*.md', '*.md']:
        md_files.extend(glob.glob(str(BASE_DIR / pattern), recursive=True))

    md_files = [Path(f) for f in md_files]

    print(f"Found {len(md_files)} markdown files")
    print()

    updated = 0
    skipped = 0
    errors = 0

    for md_file in sorted(md_files):
        result = add_disclaimer_to_file(md_file)
        if result:
            updated += 1
        elif result is False:
            skipped += 1
        else:
            errors += 1

    print()
    print("=" * 60)
    print(f"Summary:")
    print(f"  [OK] Updated: {updated}")
    print(f"  [SKIP] Skipped: {skipped}")
    print(f"  [ERROR] Errors: {errors}")
    print("=" * 60)

if __name__ == "__main__":
    main()
