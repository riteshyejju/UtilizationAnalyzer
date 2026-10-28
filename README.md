# UtilizationAnalyzer

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: macOS 14+](https://img.shields.io/badge/Platform-macOS%2014%2B-brightgreen.svg)](https://www.apple.com/macos/)
[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange.svg)](https://swift.org)

**UtilizationAnalyzer** is a lightweight, native macOS Menu Bar + Dashboard GUI application built with Swift and SwiftUI that runs silently in the background to record system-wide and per-application telemetry.

It is purpose-built to answer a practical question for anyone evaluating a new Mac (such as a **MacBook Air M5**):
> *"Is my current MacBook configuration (Unified Memory size, fanless thermal headroom, CPU/GPU cores, and SSD throughput) enough for my real-world usage, or should I upgrade?"*

---

## Key Features

### 1. MacBook Air M5 Bottleneck & Sizing Telemetry
Unlike generic system monitors, **UtilizationAnalyzer** tracks the exact hardware signals that determine whether an Apple Silicon MacBook Air is bottlenecking:
- **Unified Memory & Swap Pressure:** Tracks App Memory, Wired RAM, **Compressed RAM**, **SSD Swap Used**, Pageout rates, and macOS kernel **Memory Pressure** (`Nominal / Green`, `Warning / Yellow`, `Critical / Red`) to tell you if your 16 GB / 24 GB / 32 GB RAM tier is sufficient.
- **Fanless Thermal State & Sustained CPU Load:** Tracks `ProcessInfo.thermalState` (`Nominal`, `Fair`, `Serious`, `Critical`) alongside multi-core CPU % and **Peak Single-Core %** to detect passive thermal throttling on fanless MacBook Air chassis.
- **Apple Silicon GPU Utilization:** Queries `IOAccelerator` via `IOKit` for live GPU core utilization % and active GPU memory.
- **Per-Application Resource Grouping:** Automatically aggregates child helper processes (such as `Google Chrome Helper (Renderer)`, IDE language servers, and Electron helpers) into their parent `.app` bundle using native Darwin `libproc` (`proc_pid_rusage`) so you see each app's true CPU, Physical Memory footprint, and Disk R/W impact.
- **Disk I/O, Network Throughput & System Power:** Monitors real-time SSD Read/Write MB/s, free disk space, Network Rx/Tx MB/s, Battery percentage, and live system power draw in **Watts (`W`)**.

### 2. Native Menu Bar + Interactive Swift Charts Dashboard
- **Menu Bar Extra (`MenuBarExtra`):** Lives quietly in the macOS menu bar with optional live CPU & RAM text, a one-click popover showing live gauges, top 5 active apps, and quick actions.
- **Background Operation:** Closing the Dashboard window transitions the app cleanly to background menu bar mode without interrupting telemetry collection.
- **Interactive Charts (`Swift Charts`):** Visualize historical trends over *Last 15 Min*, *1 Hour*, *6 Hours*, *24 Hours*, *7 Days*, or *All Time* backed by a local WAL-mode SQLite database (`~/Library/Application Support/UtilizationAnalyzer/metrics.sqlite`).
- **Automated Sufficiency Scorecard (0–100):** Evaluates your hardware across four pillars (*Memory*, *CPU/Thermal*, *GPU*, *Disk/IO*) with plain-English findings.

### 3. Two-Option Export (LLM-Ready Markdown & Raw Data)
Click **Export Data** in the toolbar, Menu Bar popover, or the **LLM & Raw Export** tab to choose between:
1. **Option 1 — LLM-Ready Markdown Summary (Copy to Clipboard or Save `.md`):**
   Generates a structured report containing your hardware profile, automated sufficiency scores, **Mean / Median (p50) / 95th Percentile (p95) / Peak** tables, time spent in Yellow/Red memory pressure or elevated thermal states, top applications table, and a tailored prompt ready to paste directly into **ChatGPT, Claude, or Gemini** for a personalized hardware sizing consultation.
2. **Option 2 — Raw Telemetry Data (`.json` & `.csv`):**
   Exports the complete time-series samples and per-app aggregations for custom scripts, Jupyter notebooks, or spreadsheet analysis.

---

## Quick Start & Installation

### Requirements
- **macOS 14.0 (Sonoma)** or newer (Apple Silicon M1/M2/M3/M4/M5 & Intel supported)
- **Xcode Command Line Tools** (`xcode-select --install`) or Xcode 15+

### Build & Run from Source

```bash
# Clone the repository
git clone https://github.com/riteshyejju/UtilizationAnalyzer.git
cd UtilizationAnalyzer

# Package and launch the native UtilizationAnalyzer.app bundle
make run
```

### Install to `/Applications`

```bash
make install
open /Applications/UtilizationAnalyzer.app
```

### CLI Utilities

You can also run the built binary from the terminal to execute the self-test suite or print an instant LLM-Ready Markdown report to `stdout`:

```bash
# Run automated collector, SQLite, analyzer, and exporter tests
make test

# Print the LLM-Ready Markdown Summary directly to terminal
.build/debug/UtilizationAnalyzer --print-llm-report
```

---

## Architecture Overview

```text
Sources/UtilizationAnalyzer/
├── Models/
│   └── MetricsModels.swift           # HardwareProfile, SystemSample, AppUsageSnapshot, SufficiencyEvaluation
├── Collectors/
│   ├── SystemMetricsCollector.swift  # Mach host_processor_info, host_statistics64, sysctl, IOKit GPU/Disk/Battery
│   └── ProcessMetricsCollector.swift # Darwin libproc (proc_listallpids, proc_pid_rusage) + .app bundle grouping
├── Storage/
│   └── MetricsDatabase.swift         # Native SQLite3 (WAL mode) time-series & app aggregation store
├── Analysis/
│   ├── SufficiencyAnalyzer.swift     # p50/p95/peak percentile engine & 0-100 MacBook sizing rubric
│   └── DataExporter.swift            # Option 1: LLM Markdown Report | Option 2: Raw JSON & CSV Exporter
├── ViewModel/
│   └── MonitoringManager.swift       # Background DispatchSourceTimer & SwiftUI @MainActor state
└── Views/
    ├── DashboardView.swift           # Main split-view dashboard, Overview, Export preview, and Settings
    ├── ChartsTabView.swift           # Swift Charts for CPU, Unified Memory/Swap, GPU, Power, Disk, and Network
    ├── AppsTabView.swift             # Live & Historical per-app resource breakdown with search & sorting
    ├── MenuBarPopoverView.swift      # Compact Menu Bar popover with live gauges & quick export
    └── ThemeAndComponents.swift      # Score rings, stat cards, native app icon loader, and ExportMenuButton
```

## Contributing

Contributions, issues, and feature requests are welcome! Please read [CONTRIBUTING.md](CONTRIBUTING.md) for details on our development workflow.

## License

Distributed under the **MIT License**. See [LICENSE](LICENSE) for more information.
