# SPFresh build notes (file-I/O / no-SPDK mode)

Built on this Ubuntu 22.04 box, no sudo, no SPDK runtime. SPFresh and SPANN+ are
two run-time configs of the same `ssdserving` binary (selected via the `.ini`).

## Result: SUCCESS

Binaries (all run, print usage, no missing shared libs):

- `/home/dmo/lsm_vec_benchmark/LSM-Vec-with-SA-HNSW/bench/systems/spfresh/Release/ssdserving`
  (the SSDServing binary — used for both SPFresh and SPANN+ configs; invoked as `ssdserving <config.ini>`)
- `/home/dmo/lsm_vec_benchmark/LSM-Vec-with-SA-HNSW/bench/systems/spfresh/Release/usefultool`
  (GenTrace / ConvertTruth / CallRecall etc.)
- `/home/dmo/lsm_vec_benchmark/LSM-Vec-with-SA-HNSW/bench/systems/spfresh/Release/spfresh`
  (the SPFresh streaming driver, invoked as `spfresh <storePath>`)

RocksDB is **statically** linked into the binaries (no librocksdb runtime dependency).

## Repo layout / paths

- SPFresh repo: `/home/dmo/lsm_vec_benchmark/LSM-Vec-with-SA-HNSW/bench/systems/spfresh`
- Build dir:    `.../spfresh/Release`  (binaries land in `.../spfresh/Release/` per the repo's CMake)
- RocksDB (the SPFresh-required PtilopsisL fork, v7.6.0) source: `/home/dmo/SPFresh/rocksdb`
- RocksDB local install prefix (built with RTTI): `/home/dmo/SPFresh/rocksdb/_install`

## Why the work was needed

1. **SPDK** cannot run here and was not built. SPFresh's `AnnService/CMakeLists.txt`
   hard-links ~30 SPDK/DPDK static `.a` files that don't exist. We do not need the
   NVMe/SPDK path (`UseSPDK=false`), so we compiled it out instead of building SPDK.
2. **RocksDB RTTI**: SPFresh's `ExtraRocksDBController.h` defines
   `class AnnMergeOperator : public rocksdb::MergeOperator` (virtual overrides), which
   needs `typeinfo for rocksdb::MergeOperator`. Every system RocksDB on this box
   (`/usr/lib/.../librocksdb.{a,so}` 8.9.0, `/usr/local/.../` 9.5.0) was built
   **without RTTI**, so linking failed with
   `undefined reference to typeinfo for rocksdb::MergeOperator`.
   Fix: build the PtilopsisL RocksDB fork with `-DUSE_RTTI=1` and link against that.

## Patches made (2 files, minimal, documented inline)

### 1. `AnnService/CMakeLists.txt`
- Added the in-tree SPDK **source** headers to the include path (the configured
  `ThirdParty/spdk/build/include` does not exist because SPDK was never built) and
  defined `SPFRESH_NO_SPDK`:
  ```
  include_directories(${PROJECT_SOURCE_DIR}/ThirdParty/spdk/include)
  add_definitions(-DSPFRESH_NO_SPDK)
  ```
  (replaced the old `include_directories(${Spdk}/include)` line which pointed at the
  non-existent build dir).
- Removed `${SPDK_LIBRARIES}` from the two link lines so no SPDK/DPDK `.a` files are
  required at link time:
  ```
  target_link_libraries (SPTAGLib       DistanceUtils ${RocksDB_LIBRARIES} ${uring_LIBRARIES} libzstd_shared ${NUMA_LIBRARY}        tbb)
  target_link_libraries (SPTAGLibStatic DistanceUtils ${RocksDB_LIBRARIES} ${uring_LIBRARIES} libzstd_static ${NUMA_LIBRARY_STATIC} tbb)
  ```

### 2. `AnnService/src/Core/SPANN/ExtraSPDKController.cpp`
- Wrapped the SPDK-only code in `#ifndef SPFRESH_NO_SPDK ... #else ... #endif`.
  `SPDKIO` is referenced by the `ExtraDynamicSearcher<T>` template (so its symbols must
  link) but is never instantiated at runtime when `UseSPDK=false`. Under
  `SPFRESH_NO_SPDK` we provide SPDK-free definitions of the `BlockController` methods:
  the in-memory impl (`SPFRESH_SPDK_USE_MEM_IMPL=1`) stays functional; the NVMe/SSD
  path simply returns `false`. No `spdk_*` symbols are referenced, so no SPDK libs are
  needed. The header `ExtraSPDKController.h` is unchanged — it still parses fine against
  the in-tree `ThirdParty/spdk/include` headers (only pointer/enum decls are used).

No other source files changed.

## Exact working build commands

```bash
# ---- 1. Build the SPFresh-required RocksDB fork WITH RTTI, install to a local prefix
cd /home/dmo/SPFresh/rocksdb            # PtilopsisL/rocksdb fork (v7.6.0), already cloned
mkdir -p build && cd build
cmake -DUSE_RTTI=1 -DWITH_JEMALLOC=1 -DWITH_SNAPPY=1 \
      -DCMAKE_C_COMPILER=gcc-9 -DCMAKE_CXX_COMPILER=g++-9 \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_FLAGS="-fPIC" \
      -DWITH_TESTS=OFF -DWITH_BENCHMARK_TOOLS=OFF -DWITH_TOOLS=OFF -DWITH_CORE_TOOLS=OFF \
      -DROCKSDB_BUILD_SHARED=ON -DFAIL_ON_WARNINGS=OFF \
      -DCMAKE_INSTALL_PREFIX=/home/dmo/SPFresh/rocksdb/_install \
      ..
make -j32 rocksdb rocksdb-shared
make install        # installs to the local prefix above -- NO sudo

# ---- 2. Build SPFresh (file-I/O / no-SPDK), pointing CMake at the RTTI RocksDB
cd /home/dmo/lsm_vec_benchmark/LSM-Vec-with-SA-HNSW/bench/systems/spfresh
mkdir -p Release && cd Release
cmake -DCMAKE_BUILD_TYPE=Release -DGPU=OFF \
      -DCMAKE_C_COMPILER=gcc-9 -DCMAKE_CXX_COMPILER=g++-9 \
      -DRocksDB_DIR=/home/dmo/SPFresh/rocksdb/_install/lib/cmake/rocksdb \
      ..
make -j32 ssdserving usefultool spfresh
```

(`indexbuilder` and the other LIBRARYONLY=OFF targets also build with plain `make -j32`
if needed; only the three above were required.)

## Selecting the file-I/O (non-SPDK) backend in the `.ini`

Backend is chosen at runtime in `SPANNIndex.cpp` from the `[BuildSSDIndex]` section:
- `UseKV=true`   -> RocksDB file-I/O backend (`RocksDBIO`), uses dir given by `KVPath`
- `UseSPDK=true` -> SPDK/NVMe backend (NOT available in this build)
- both false     -> static searcher (no streaming)

The sample inis under `Script_AE/iniFile/.../indexloader_*.ini` ship with
`UseSPDK=true` + `UseDirectIO=true`. For this build, edit the `[BuildSSDIndex]` section to:

```
UseSPDK=false
UseKV=true
KVPath=/path/to/rocksdb_store_dir
UseDirectIO=false        ; (RocksDB-backed; direct IO optional)
```

Relevant option plumbing (`AnnService/inc/Core/SPANN/ParameterDefinitionList.h`):
`m_useKV`="UseKV", `m_useSPDK`="UseSPDK", `m_KVPath`="KVPath", `m_useDirectIO`="UseDirectIO".

SPFresh vs SPANN+ are otherwise the same binary/backend; they differ by the LIRE-protocol
update options in the ini (e.g. reassign/merge settings), not by the storage backend.
```
