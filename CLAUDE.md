# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

RTAB-Map (Real-Time Appearance-Based Mapping) — a C++ RGB-D / stereo / lidar graph-based SLAM library plus a Qt standalone application and a large collection of CLI/GUI tools. BSD licensed. The canonical entry point for users/integrators is the `rtabmap::Rtabmap` class; ROS integration lives in a separate `rtabmap_ros` / `rtabmap_ros2` repo.

## Build

CMake only — there is no `make` / npm / cargo wrapper. Out-of-tree builds under `build/`:

```
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
```

Binaries land in `build/bin/` (executables are prefixed `rtabmap-`, e.g. `rtabmap-console`, `rtabmap-databaseViewer`, `rtabmap-reprocess`). Smoke check: `./build/bin/rtabmap-console --version`.

Common CMake options (all toggled at configure time — there are ~50+ `WITH_*` flags; do not add new ones casually):
- `BUILD_APP` / `BUILD_TOOLS` / `BUILD_EXAMPLES` (all ON by default)
- `WITH_QT` (default ON, required for GUI; disables `rtabmap_gui` and GUI tools when OFF)
- `RTABMAP_QT_VERSION` = `AUTO|4|5|6`
- `WITH_G2O` / `WITH_GTSAM` / `WITH_CERES` / `WITH_TORO` — graph optimizer backends
- `WITH_PYTHON` — enables PyMatcher/PyDetector (CI sets this ON)
- `WITH_TORCH` — SuperPoint features
- `WITH_POINTMATCHER`, `WITH_OCTOMAP`, `WITH_OPEN3D`, `WITH_OPENGV` (+ `BUILD_OPENGV` to fetch/build internally via `FetchContent`)
- Many sensor drivers (`WITH_REALSENSE2`, `WITH_K4A`, `WITH_ZED`, `WITH_FREENECT2`, `WITH_DEPTHAI`, …)

C++ standard is auto-selected: C++17 when Qt6 / Torch / MRPT / newer g2o are present, C++14 when newer PCL / LOAM / MSCKF / CCCoreLib are present, otherwise C++11. Don't hardcode the standard.

### CI and Docker

CI builds (see `.github/workflows/`):
- `cmake-linux.yml` — Ubuntu 22.04 + 24.04 (+ a `-DBUILD_OPENGV=ON` variant), with `-DWITH_CERES=ON -DWITH_PYTHON=ON`.
- `cmake-windows.yml` — vcpkg + `-DBUILD_AS_BUNDLE=ON`, with and without CUDA/Torch.
- `cmake-ros.yml` — humble / jazzy / kilted / rolling via `rosdep`.

CI does **not** run `ctest`. There is no test suite registered via `add_test` / `enable_testing` — the build itself plus the `--version` smoke is the gate. If you want to exercise behavior, use the examples under `examples/` or the `tools/` binaries against sample data in `data/` (e.g. `data/samples.zip`).

Dockerfiles for many Ubuntu / ROS combinations live under `docker/`.

## Architecture

Three layered libraries are built in order: `rtabmap_utilite` → `rtabmap_core` → `rtabmap_gui`. An interface library `rtabmap::rtabmap` re-exports them for downstream `find_package(RTABMap)` consumers.

### `utilite/` — foundation

Header-only-ish cross-platform utilities. Threading (`UThread` / `UThreadNode`), logging (`ULogger`), mutex/semaphore, STL helpers, and **the application-wide event bus**: `UEventsManager` is a singleton to which handlers (`UEventsHandler` subclasses) register and to which any thread posts `UEvent*` with `UEventsManager::post(new MyEvent())`. Ownership transfers on post. Many `*Event` classes in `corelib` (`CameraEvent`, `OdometryEvent`, `SensorEvent`, `RtabmapEvent`, `ParamEvent`, …) are how the camera thread → odometry thread → rtabmap thread pipeline communicates.

### `corelib/` — the SLAM engine

Public headers under `corelib/include/rtabmap/core/`; sources under `corelib/src/` with subfolders `camera/`, `lidar/`, `odometry/`, `optimizer/`, `opencv/`, `stereo/`, `icp/`, `imufilter/`, `clams/`, `python/`, `global_map/`, plus vendored `sqlite3/`, `rtflann/`, `pcl18/`, `superpoint_torch/`, `superpoint_rpautrat/`.

Key classes and how they fit together:

- `Rtabmap` (Rtabmap.h) — top-level SLAM object. `process(SensorData, odomPose, …)` is the main per-frame entry point. Manages loop-closure detection, proximity detection, graph optimization invocation, and statistics.
- `RtabmapThread` — `UThread` wrapper that runs `Rtabmap::process` off events from the bus. `Odometry` + `OdometryThread` and `Camera`/`SensorCapture` + `SensorCaptureThread` / `CameraThread` are the analogous thread-wrapper pairs for odometry and capture.
- `Memory` — STM / WM / LTM hierarchy. New signatures enter Short-Term Memory, are promoted to Working Memory, and retired to Long-Term Memory (backed by SQLite via `DBDriverSqlite3`). Central to how the system scales.
- `BayesFilter` + `VWDictionary` + `VisualWord` — appearance-based loop-closure detection (bag-of-words over Working Memory).
- `Optimizer` — abstract base with backends in `optimizer/`: `OptimizerG2O`, `OptimizerGTSAM`, `OptimizerTORO`, `OptimizerCeres`, `OptimizerCVSBA`. Chosen at runtime via the `Optimizer/Strategy` parameter.
- `Odometry` — abstract base with many backends in `odometry/` (F2M, F2F, Mono, plus pluggable external systems: ORB-SLAM2/3, Fovis, VISO2, DVO, OKVIS, MSCKF-VIO, VINS-Fusion, OpenVINS, LOAM, FLOAM, LIO-SAM, Open3D, cuVSLAM). Most are gated by `WITH_*`.
- `Registration` (+ `RegistrationVis`, `RegistrationIcp`) — pairwise alignment used in loop closures and proximity detection.
- `SensorCapture` / `Camera` / `Lidar` families — dozens of driver wrappers in `camera/` and `lidar/`, each gated by a `WITH_*` flag.
- `DBDriver` / `DBDriverSqlite3` — all persistence (map, poses, features, blobs). Databases are the primary on-disk format and are consumed by `tools/DatabaseViewer`, `tools/Reprocess`, `tools/Export`, `tools/Report`, etc.

#### Parameter system (important)

Every runtime knob lives in `corelib/include/rtabmap/core/Parameters.h` and is declared with `RTABMAP_PARAM(Group, Name, type, default, "description")` (or `RTABMAP_PARAM_STR`). The macro registers the default at static-init time into a global `ParametersMap` (`std::map<std::string,std::string>`) keyed by `"Group/Name"` (e.g. `"SURF/Extended"`, `"Rtabmap/DetectionRate"`). Accessors are `Parameters::kGroupName()` (key) and `Parameters::defaultGroupName()` (default). Any new tunable must go through this macro so it shows up in the GUI `ParametersToolBox`, is serialized to DB, and round-trips with `--params`.

Parameters are consumed via `parseParameters(const ParametersMap&)` on each component (Memory, Odometry, Optimizer, Registration, …). Don't add private constructor args for something that should be a parameter.

### `guilib/` — Qt GUI library (rtabmap_gui)

Qt + VTK based. `MainWindow` is the hub; `DatabaseViewer` is a full editor for rtabmap DBs; `CloudViewer` is the VTK point-cloud widget used across multiple dialogs; `GraphViewer` draws the pose graph; `ParametersToolBox` auto-generates widgets from the `Parameters.h` registry. Export/post-processing is spread across `Export*Dialog.cpp` + `PostProcessingDialog.cpp`.

**Qt macro note:** the build defines `-DQT_NO_KEYWORDS` to avoid clashes with Boost signals/foreach. Use `Q_SIGNALS`, `Q_SLOTS`, `Q_EMIT` — not `signals` / `slots` / `emit` — in any new Qt code.

### `app/`, `tools/`, `examples/`

- `app/src/main.cpp` is the standalone GUI (`rtabmap`).
- `tools/*/` are independent CMake targets; each becomes a `rtabmap-<toolname>` binary. GUI-dependent tools (`DatabaseViewer`, `OdometryViewer`, `Calibration`, `DataRecorder`, `CameraRGBD`, `LidarViewer`, `Matcher`, `EpipolarGeometry`) only build when `rtabmap_gui` is built (see `tools/CMakeLists.txt`).
- `examples/` shows how to drive the library without the GUI (`NoEventsExample`) and with it (`RGBDMapping`, `LidarMapping`, `BOWMapping`, `WifiMapping`).

## Conventions when editing

- Symbols visible across the DLL boundary need `RTABMAP_CORE_EXPORT` / `RTABMAP_GUI_EXPORT` / `UTILITE_EXPORT` macros. These are generated by CMake (`GenerateExportHeader`) into e.g. `rtabmap_core_export.h` — don't hand-roll them.
- The project uses the bus (`UEventsManager`) rather than callbacks for cross-thread wiring. New asynchronous work should follow that pattern (define a `UEvent` subclass, post it, handle in a `UEventsHandler`).
- Shared libs by default (`BUILD_SHARED_LIBS=ON`). Debug builds get a `d` suffix on libraries.
- Vendored third-party code (`corelib/src/rtflann/`, `corelib/src/sqlite3/`, `corelib/src/pcl18/`, `corelib/src/superpoint_torch/`, `guilib/src/3rdParty/`) should generally be left alone — upstream sync/patch path is via `patches/` and `FetchContent`.
- Versioning: bumping a release means editing `RTABMAP_MAJOR/MINOR/PATCH_VERSION` in the top-level `CMakeLists.txt`; `Version.h` is generated from `Version.h.in`.
