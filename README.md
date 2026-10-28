# UtilizationAnalyzer

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: macOS 14+](https://img.shields.io/badge/Platform-macOS%2014%2B-brightgreen.svg)](https://www.apple.com/macos/)
[![Download DMG](https://img.shields.io/badge/Download-UtilizationAnalyzer.dmg-0A84FF?logo=apple)](https://github.com/riteshyejju/UtilizationAnalyzer/releases/latest/download/UtilizationAnalyzer.dmg)

A lightweight, native macOS Menu Bar + Dashboard app (Swift & SwiftUI) that runs in the background to monitor system and per-application resource utilization. Built to help you evaluate whether your Mac hardware fits your real-world workload.

---

## Download & Install

### Option A: Direct `.dmg` Download
- [**Download UtilizationAnalyzer.dmg**](https://github.com/riteshyejju/UtilizationAnalyzer/releases/latest/download/UtilizationAnalyzer.dmg) *(also in [`releases/UtilizationAnalyzer.dmg`](releases/UtilizationAnalyzer.dmg))*
- Open `UtilizationAnalyzer.dmg` and drag **UtilizationAnalyzer.app** to `/Applications`.

### Option B: One-Step Install (Auto-Downloads & Opens)
```bash
curl -fsSL https://raw.githubusercontent.com/riteshyejju/UtilizationAnalyzer/main/install.sh | bash
```

---

## Features

- **System Telemetry:** Multi-core & single-core peak CPU %, Unified/Physical RAM, Compressed RAM, SSD Swap usage, Memory Pressure (`Nominal`, `Warning`, `Critical`), Thermal State (`Nominal`, `Fair`, `Serious`, `Critical`), GPU %, Disk Read/Write & Free Space, Network Rx/Tx, Battery %, and Power Draw (`W`).
- **Per-App Resource Grouping:** Automatically aggregates child helper processes (browser renderers, IDE language servers, GPU helpers) into their parent `.app` bundle for accurate per-app CPU, Memory, and Disk I/O tracking.
- **Interactive Dashboard & Menu Bar Extra:** Real-time menu bar popover plus a full `Swift Charts` dashboard across *15m*, *1h*, *6h*, *24h*, *7d*, and *All Time* windows stored in local SQLite (`~/Library/Application Support/UtilizationAnalyzer/metrics.sqlite`).
- **Hardware Sufficiency Scorecard (0–100):** Automated evaluation across Memory, CPU/Thermal, GPU, and Disk/IO headroom.
- **Two-Option Data Export:**
  1. **LLM-Ready Markdown Summary:** Copy to clipboard or save `.md` with `mean` / `p50` / `p95` / `peak` stats, bottleneck indicators, top apps, and an embedded prompt for ChatGPT, Claude, or Gemini.
  2. **Raw Telemetry Data:** Export full time-series data as `.json` or `.csv`.

---

## Build from Source

Requires macOS 14.0+ and Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/riteshyejju/UtilizationAnalyzer.git
cd UtilizationAnalyzer

make run       # Build and launch UtilizationAnalyzer.app
make dmg       # Build UtilizationAnalyzer.app + releases/UtilizationAnalyzer.dmg
make install   # Install to /Applications/UtilizationAnalyzer.app
make test      # Run automated self-test suite
```

## License

MIT License — see [LICENSE](LICENSE).
