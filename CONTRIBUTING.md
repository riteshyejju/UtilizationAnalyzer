# Contributing to UtilizationAnalyzer

Thank you for your interest in contributing to **UtilizationAnalyzer**! This project helps Mac users evaluate whether their current MacBook hardware (Unified Memory, CPU/GPU cores, fanless vs. active cooling, and SSD throughput) is well-sized for their real-world workload.

## Getting Started

### Prerequisites
- macOS 14.0 (Sonoma) or newer
- Xcode Command Line Tools (`xcode-select --install`) or Xcode 15+
- Swift 5.9+

### Building & Testing Locally

```bash
# 1. Clone the repository
git clone https://github.com/riteshyejju/UtilizationAnalyzer.git
cd UtilizationAnalyzer

# 2. Build and run the automated self-test suite
make test

# 3. Package and launch the native macOS .app bundle
make run
```

## Project Structure

- `Sources/UtilizationAnalyzer/Models/` — Core data models (`HardwareProfile`, `SystemSample`, `AppUsageSnapshot`, `SufficiencyEvaluation`).
- `Sources/UtilizationAnalyzer/Collectors/` — Low-overhead Darwin/Mach/IOKit system and process telemetry collectors (`SystemMetricsCollector`, `ProcessMetricsCollector`).
- `Sources/UtilizationAnalyzer/Storage/` — Local SQLite3 WAL persistence engine (`MetricsDatabase`) with time-window queries and downsampling.
- `Sources/UtilizationAnalyzer/Analysis/` — Hardware sufficiency scoring (`SufficiencyAnalyzer`) and two-mode data exporter (`DataExporter` for LLM-Ready Markdown and Raw JSON/CSV).
- `Sources/UtilizationAnalyzer/ViewModel/` — Background dispatch timer and SwiftUI state coordinator (`MonitoringManager`).
- `Sources/UtilizationAnalyzer/Views/` — Menu bar popover (`MenuBarPopoverView`) and full telemetry dashboard (`DashboardView`, `ChartsTabView`, `AppsTabView`).

## Design Principles

1. **Near-Zero Monitoring Overhead:** Avoid spawning external shell processes in the periodic sampling loop. Use native Mach (`host_processor_info`, `host_statistics64`), `sysctl`, `libproc` (`proc_listallpids`, `proc_pid_rusage`), and `IOKit` APIs so the monitor itself never skews CPU, memory, or battery measurements.
2. **Application-Level Grouping:** Group child helper processes (such as browser renderers and IDE language servers) into their parent `.app` bundle so users see true per-application footprints.
3. **Actionable Hardware Sizing:** Every metric collected should help answer practical questions like *"Is 16 GB Unified Memory enough, or do I need 24 GB / 32 GB?"* and *"Is the fanless MacBook Air throttling under my workload?"*

## Submitting Pull Requests

1. Fork the repository and create a feature branch (`git checkout -b feat/your-feature`).
2. Verify that `make test` and `make app` succeed without warnings or errors.
3. Open a Pull Request with a clear summary of your changes and any screenshots if modifying the GUI.
