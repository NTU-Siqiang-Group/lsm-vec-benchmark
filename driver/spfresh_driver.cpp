// SPFresh / SPANN+ orchestrator driver for the shared LSM-Vec benchmark trace.
//
// Builds nothing itself: it LOADS an SSD index already built by `ssdserving`
// (file-I/O / RocksDB backend, UseKV=true, UseSPDK=false) and then replays OUR
// exact per-epoch ins/del global-id lists through the SPANN dynamic API
// (AddIndexSPFresh / DeleteIndex), running OUR full query set each epoch and
// computing recall@10 against OUR gt100 (global-id top-100). Emits the shared
// per-epoch JSONL schema. SPFresh vs SPANN+ is purely the loaded index's ini
// (LIRE/rebuilder on vs off); this driver is identical for both.
//
// NOTE: latencies here are FILE-I/O (RocksDB) latencies, NOT the paper's SPDK
// numbers -- this build has no SPDK runtime.
//
// Usage:
//   spfresh_driver --store <indexDir> --trace <traceDir> --out <jsonl>
//                  --dim D --epochs N --k 10 --ef 64 [--epoch-file F]
//
// Vector / id layout (see driver/trace_format.md):
//   base.fbin/base.ids.u32  pool.fbin/pool.ids.u32  query.fbin
//   epoch_%03d.ins.u32 / .del.u32   gt/epoch_%03d.gt100
// Global ids are stable; base ids default 0..N-1, pool ids N..N+P-1.

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <string>
#include <vector>
#include <set>
#include <algorithm>
#include <chrono>
#include <sstream>
#include <fstream>
#include <filesystem>
#include <thread>

#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>

#include "inc/Core/Common.h"
#include "inc/Core/VectorIndex.h"
#include "inc/Core/SPANN/Index.h"
#include "inc/Core/SearchQuery.h"

using namespace SPTAG;
namespace fs = std::filesystem;

// Element type of the stored vectors (PVLDB revision Step 1: native-byte baselines).
// Build with -DSPF_VT_UINT8 (SIFT, reads <name>.u8bin) or -DSPF_VT_INT8 (SPACEV, <name>.i8bin);
// default is float (<name>.fbin), the V2 configuration. The driver logic is identical in all three.
#if defined(SPF_VT_UINT8)
using VT = std::uint8_t;  static const char* kExt = "u8bin"; static const VectorValueType kVVT = VectorValueType::UInt8;
#elif defined(SPF_VT_INT8)
using VT = std::int8_t;   static const char* kExt = "i8bin"; static const VectorValueType kVVT = VectorValueType::Int8;
#else
using VT = float;         static const char* kExt = "fbin";  static const VectorValueType kVVT = VectorValueType::Float;
#endif

// ---------- small binary readers (host little-endian) ----------
static std::vector<uint32_t> readU32(const std::string& path) {
    std::vector<uint32_t> v;
    std::ifstream f(path, std::ios::binary);
    if (!f) return v;
    f.seekg(0, std::ios::end); auto sz = f.tellg(); f.seekg(0);
    v.resize((size_t)sz / 4);
    if (!v.empty()) f.read((char*)v.data(), (std::streamsize)v.size() * 4);
    return v;
}

// .fbin: int32 n, int32 d, float32[n*d]
static bool readFbin(const std::string& path, int32_t& n, int32_t& d, std::vector<VT>& data) {
    std::ifstream f(path, std::ios::binary);
    if (!f) return false;
    f.read((char*)&n, 4); f.read((char*)&d, 4);
    data.resize((size_t)n * d);
    f.read((char*)data.data(), (std::streamsize)(data.size() * sizeof(VT)));
    return (bool)f;
}

// .gt100: uint32 nq, uint32 K, uint32 ids[nq*K], float dists[nq*K]
static bool readGt(const std::string& path, uint32_t& nq, uint32_t& K, std::vector<uint32_t>& ids) {
    std::ifstream f(path, std::ios::binary);
    if (!f) return false;
    f.read((char*)&nq, 4); f.read((char*)&K, 4);
    ids.resize((size_t)nq * K);
    f.read((char*)ids.data(), (std::streamsize)ids.size() * 4);
    return (bool)f;
}

static double rssMb() {
    std::ifstream f("/proc/self/status");
    std::string k;
    while (f >> k) {
        if (k == "VmRSS:") { long kb; f >> kb; return kb / 1024.0; }
        f.ignore(1 << 20, '\n');
    }
    return 0.0;
}

static double dirMb(const std::string& dir) {
    std::error_code ec; uintmax_t tot = 0;
    if (!fs::exists(dir, ec)) return 0.0;
    for (auto it = fs::recursive_directory_iterator(dir, fs::directory_options::skip_permission_denied, ec);
         it != fs::recursive_directory_iterator(); it.increment(ec)) {
        std::error_code e2;
        if (it->is_regular_file(e2)) tot += it->file_size(e2);
    }
    return tot / (1024.0 * 1024.0);
}

static std::string argval(int argc, char** argv, const std::string& key, const std::string& def = "") {
    for (int i = 1; i + 1 < argc; ++i) if (key == argv[i]) return argv[i + 1];
    return def;
}

// Cumulative physical disk I/O of this process (incl. RocksDB background
// compaction threads — the deferred write-amplification) from /proc/self/io.
static void procIO(unsigned long long& rd, unsigned long long& wr) {
    rd = wr = 0;
    FILE* f = fopen("/proc/self/io", "r");
    if (!f) return;
    char key[64];
    unsigned long long v;
    while (fscanf(f, "%63s %llu", key, &v) == 2) {
        if (!strcmp(key, "read_bytes:")) rd = v;
        else if (!strcmp(key, "write_bytes:")) wr = v;
    }
    fclose(f);
}

// mmap an .fbin read-only; returns pointer to row 0 (payload at byte 8, 4B-aligned).
// Pages are file-backed: evictable, and excluded from RssAnon — the driver's copy
// of the workload data no longer contaminates the measured (anon) memory.
static const VT* mmapFbin(const std::string& path, int32_t& n, int32_t& d) {
    int fd = open(path.c_str(), O_RDONLY);
    if (fd < 0) return nullptr;
    if (pread(fd, &n, 4, 0) != 4 || pread(fd, &d, 4, 4) != 4 || n <= 0 || d <= 0) { close(fd); return nullptr; }
    size_t need = 8 + (size_t)n * d * sizeof(VT);
    void* addr = mmap(nullptr, need, PROT_READ, MAP_SHARED, fd, 0);
    close(fd);
    if (addr == MAP_FAILED) return nullptr;
    return reinterpret_cast<const VT*>(static_cast<char*>(addr) + 8);
}

static double rssAnonMb() {
    std::ifstream f("/proc/self/status");
    std::string k;
    while (f >> k) {
        if (k == "RssAnon:") { long kb; f >> kb; return kb / 1024.0; }
        f.ignore(1 << 20, '\n');
    }
    return 0.0;
}

int main(int argc, char** argv) {
    std::string store = argval(argc, argv, "--store");
    std::string trace = argval(argc, argv, "--trace");
    std::string out   = argval(argc, argv, "--out");
    std::string epochFile = argval(argc, argv, "--epoch-file");
    int dim     = std::stoi(argval(argc, argv, "--dim", "0"));
    int nEpochs = std::stoi(argval(argc, argv, "--epochs", "0"));
    int K       = std::stoi(argval(argc, argv, "--k", "10"));
    int ef      = std::stoi(argval(argc, argv, "--ef", "64"));
    if (store.empty() || trace.empty() || out.empty() || dim == 0 || nEpochs == 0) {
        fprintf(stderr, "missing args; need --store --trace --out --dim --epochs\n");
        return 2;
    }
    if (ef < K) ef = K;

    auto setEpoch = [&](int e) {
        if (epochFile.empty()) return;
        std::ofstream f(epochFile, std::ios::trunc); f << e << "\n";
    };
    setEpoch(-1);

    // ---- load the prebuilt SSD index (reads <store>/indexloader.ini) ----
    std::shared_ptr<VectorIndex> vindex;
    if (VectorIndex::LoadIndex(store, vindex) != ErrorCode::Success || vindex == nullptr) {
        fprintf(stderr, "FATAL: failed to load index from %s\n", store.c_str());
        return 1;
    }
    if (vindex->GetVectorValueType() != kVVT) {
        fprintf(stderr, "FATAL: index value type does not match this driver build (%s)\n", kExt);
        return 1;
    }
    auto* index = static_cast<SPANN::Index<VT>*>(vindex.get());
    auto* opts = index->GetOptions();
    opts->m_searchInternalResultNum = ef;
    opts->m_resultNum = K;
    // leave m_inPlace at its loaded default (merge/reassign enabled) so deleted
    // head vectors get reassigned out, matching native SPFresh behavior.
    std::string kvPath = opts->m_KVPath;

    fprintf(stderr, "[driver] distCalcMethod(opts)=%d spann.GetDistCalcMethod=%d head.GetDistCalcMethod=%d\n",
            (int)opts->m_distCalcMethod, (int)index->GetDistCalcMethod(),
            (int)index->GetMemoryIndex()->GetDistCalcMethod());
    fprintf(stderr, "[driver] loaded index: dim=%d useKV=%d KVPath=%s baseN=%d\n",
            (int)index->GetFeatureDim(), (int)opts->m_useKV, kvPath.c_str(), (int)index->GetNumSamples());
    if ((int)index->GetFeatureDim() != dim)
        fprintf(stderr, "[driver] WARNING: index dim %d != --dim %d\n", (int)index->GetFeatureDim(), dim);

    // ---- map base+pool vectors (file-backed, zero anon-heap contamination) ----
    int32_t bn = 0, bd = 0, pn = 0, pd = 0;
    const VT* bmap = mmapFbin(trace + "/base." + kExt, bn, bd);
    if (!bmap) { fprintf(stderr, "FATAL: base.%s\n", kExt); return 1; }
    const VT* pmap = mmapFbin(trace + "/pool." + kExt, pn, pd);  // may be absent
    std::vector<uint32_t> bids = readU32(trace + "/base.ids.u32");
    std::vector<uint32_t> pids = readU32(trace + "/pool.ids.u32");
    if ((int)bids.size() != bn) { fprintf(stderr, "FATAL: base ids/vec mismatch\n"); return 1; }
    // Trace convention (asserted): base ids 0..bn-1, pool ids bn..bn+pn-1.
    for (int i = 0; i < pn; ++i)
        if (pids[i] != (uint32_t)(bn + i)) { fprintf(stderr, "FATAL: pool ids not contiguous\n"); return 1; }
    size_t G = (size_t)bn + (size_t)pn;
    auto gidVec = [&](uint32_t g) -> const VT* {
        return g < (uint32_t)bn ? bmap + (size_t)g * bd : pmap + (size_t)(g - bn) * pd;
    };
    auto haveVecAt = [&](uint32_t g) { return (size_t)g < G; };
    // Aligned scratch: SPTAG's SIMD paths get a 64B-aligned copy, not the mmap pointer.
    alignas(64) static VT scratch[4096];

    // base was built in base.ids order; assert default 0..N-1 so VID==gid for base
    bool baseIdentity = true;
    for (int i = 0; i < bn; ++i) if (bids[i] != (uint32_t)i) { baseIdentity = false; break; }
    if (!baseIdentity) { fprintf(stderr, "FATAL: base ids not 0..N-1; VID mapping assumption broken\n"); return 1; }

    // ---- id <-> VID maps ----
    long long baseVID = index->GetNumSamples();   // == bn
    std::vector<int64_t> gid2vid(G, -1);          // global id -> current SPANN VID
    long long maxVID = baseVID + (long long)pn + 16;
    std::vector<int64_t> vid2gid(maxVID, -1);     // SPANN VID -> global id
    for (int i = 0; i < bn; ++i) { gid2vid[i] = i; vid2gid[i] = i; }
    std::vector<char> isLive(G, 0);
    for (int i = 0; i < bn; ++i) isLive[i] = 1;
    long long liveN = bn;

    // ---- query set ----
    int32_t qn, qd; std::vector<VT> qdata;
    if (!readFbin(trace + "/query." + kExt, qn, qd, qdata)) { fprintf(stderr, "FATAL: query.%s\n", kExt); return 1; }

    index->Initialize();  // init RocksDB block/searcher resources

    std::ofstream jsonl(out, std::ios::trunc);
    auto nowMs = [] { return std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now().time_since_epoch()).count(); };

    // iso-recall Pareto: --query-sweep "a,b,c" ef values, swept query-only at epoch 0 + last.
    std::vector<int> sweepEfs;
    { std::string sw = argval(argc, argv, "--query-sweep");
      std::stringstream ss(sw); std::string t;
      while (std::getline(ss, t, ',')) if (!t.empty()) sweepEfs.push_back(std::atoi(t.c_str())); }
    std::ofstream sweepJs;
    if (!sweepEfs.empty()) sweepJs.open(out + ".sweep.jsonl", std::ios::trunc);

    long long delAppearTotal = 0;  // sanity: deleted ids surfacing in results

    // ---- concurrent-workload mode (plan §1): single-thread interleave, NO AllFinished drain,
    // so SPFresh's background split/reassign jobs overlap the query bursts. Emits a per-second
    // timeline. --concurrent-rate R>0 throttles the writer to R ops/s (Mode B). ----
    bool ccMode = false;
    for (int i = 1; i < argc; ++i) if (!strcmp(argv[i], "--concurrent")) ccMode = true;
    double ccRate = atof(argval(argc, argv, "--concurrent-rate", "0").c_str());
    if (ccMode) {
        const int WB = 100, QB = 100;
        double t0ms = nowMs();
        auto elapsed = [&] { return (nowMs() - t0ms) / 1000.0; };
        double nextSample = 1.0;
        long long opsDone = 0; size_t qCursor = 0;
        std::vector<double> winLats; long long winWrites = 0; double winStart = 0;
        auto emit = [&](int ep, double now) {
            std::sort(winLats.begin(), winLats.end());
            auto pct = [&](double p) { return winLats.empty() ? 0.0
                : winLats[std::min((size_t)(p * winLats.size()), winLats.size() - 1)]; };
            double dt = now - winStart;
            jsonl << "{\"t_sec\":" << now << ",\"epoch\":" << ep
                  << ",\"live_n\":" << liveN
                  << ",\"ingest_ops_s\":" << (dt > 0 ? winWrites / dt : 0.0)
                  << ",\"qps\":" << (dt > 0 ? winLats.size() / dt : 0.0)
                  << ",\"lat_p50_ms\":" << pct(0.50) << ",\"lat_p99_ms\":" << pct(0.99)
                  << ",\"lat_max_ms\":" << (winLats.empty() ? 0.0 : winLats.back())
                  << ",\"rss_anon_mb\":" << rssAnonMb() << "}\n";
            jsonl.flush();
            winLats.clear(); winWrites = 0; winStart = now;
        };
        auto oneQuery = [&](int qi, std::vector<int64_t>& rg) {
            QueryResult res(&qdata[(size_t)qi * qd], ef, false); res.Reset();
            SPANN::SearchStats st; st.m_totalLatency = 0;
            double s = nowMs();
            index->GetMemoryIndex()->SearchIndex(res);
            index->SearchDiskIndex(res, &st);
            double ms = nowMs() - s;
            std::vector<std::pair<float, SizeType>> cand; cand.reserve(ef);
            for (int j = 0; j < ef; ++j) { auto* r = res.GetResult(j); if (r && r->VID >= 0) cand.emplace_back(r->Dist, r->VID); }
            std::sort(cand.begin(), cand.end());
            for (int j = 0; j < K && j < (int)cand.size(); ++j) {
                SizeType v = cand[j].second;
                rg.push_back((v < (SizeType)vid2gid.size()) ? vid2gid[v] : -1);
            }
            return ms;
        };
        for (int e = 0; e < nEpochs; ++e) {
            char buf[64];
            snprintf(buf, sizeof buf, "/epoch_%03d.del.u32", e);
            std::vector<uint32_t> dels = readU32(trace + buf);
            snprintf(buf, sizeof buf, "/epoch_%03d.ins.u32", e);
            std::vector<uint32_t> inss = readU32(trace + buf);
            setEpoch(e);
            size_t di = 0, ii = 0;
            while (di < dels.size() || ii < inss.size()) {
                for (int b = 0; b < WB && (di < dels.size() || ii < inss.size()); ++b) {
                    if (di < dels.size()) {
                        uint32_t g = dels[di++];
                        if (g < G && gid2vid[g] >= 0) { index->DeleteIndex((SizeType)gid2vid[g]); isLive[g] = 0; gid2vid[g] = -1; liveN--; }
                    } else {
                        uint32_t g = inss[ii++];
                        if (g < G && haveVecAt(g)) {
                            SizeType vid = -1;
                            memcpy(scratch, gidVec(g), sizeof(VT) * dim);
                            if (index->AddIndexSPFresh(scratch, 1, dim, &vid) == ErrorCode::Success) {
                                if (vid >= (SizeType)vid2gid.size()) vid2gid.resize((size_t)vid + 1024, -1);
                                gid2vid[g] = vid; vid2gid[vid] = g; isLive[g] = 1; liveN++;
                            }
                        }
                    }
                    ++opsDone; ++winWrites;
                }
                if (ccRate > 0) { double want = opsDone / ccRate, have = elapsed();
                    if (want > have) std::this_thread::sleep_for(std::chrono::duration<double>(want - have)); }
                for (int b = 0; b < QB; ++b) {
                    std::vector<int64_t> rg; winLats.push_back(oneQuery(qCursor % qn, rg)); ++qCursor;
                }
                double now = elapsed();
                if (now >= nextSample) { emit(e, now); nextSample = now + 1.0; }
            }
            snprintf(buf, sizeof buf, "/gt/epoch_%03d.gt100", e);
            uint32_t gnq = 0, gK = 0; std::vector<uint32_t> gids;
            if (readGt(trace + buf, gnq, gK, gids) && (int)gnq == qn) {
                // Coarse band on a 2000 subsample — short pause, no maintenance-drain artifact.
                int nrq = std::min(qn, 2000);
                double rsum = 0;
                for (int i = 0; i < nrq; ++i) {
                    std::vector<int64_t> rg; oneQuery(i, rg);
                    std::set<int64_t> truth;
                    for (int j = 0; j < 10 && j < (int)gK; ++j) truth.insert((int64_t)gids[(size_t)i * gK + j]);
                    int hit = 0; for (int j = 0; j < 10 && j < (int)rg.size(); ++j) if (rg[j] >= 0 && truth.count(rg[j])) hit++;
                    rsum += hit / 10.0;
                }
                jsonl << "{\"t_sec\":" << elapsed() << ",\"epoch\":" << e
                      << ",\"recall10\":" << (rsum / nrq) << ",\"live_n\":" << liveN << "}\n";
                jsonl.flush();
            }
        }
        if (!winLats.empty()) emit(nEpochs - 1, elapsed());
        fprintf(stderr, "[concurrent] spfresh done -> %s\n", out.c_str());
        return 0;
    }

    for (int e = 0; e < nEpochs; ++e) {
        char buf[64];
        // ---- deletes ----
        snprintf(buf, sizeof buf, "/epoch_%03d.del.u32", e);
        std::vector<uint32_t> dels = readU32(trace + buf);
        double t0 = nowMs();
        long long delDone = 0;
        for (uint32_t g : dels) {
            if (g >= G || gid2vid[g] < 0) continue;       // not present -> skip
            ErrorCode dc = index->DeleteIndex((SizeType)gid2vid[g]);
            if (dc != ErrorCode::Success && getenv("SPF_DEBUG"))
                fprintf(stderr, "[dbg] DELETE FAIL gid=%u vid=%lld code=%d\n", g, gid2vid[g], (int)dc);
            isLive[g] = 0; gid2vid[g] = -1; delDone++;
        }
        double tDel = nowMs() - t0;

        // ---- inserts ----
        snprintf(buf, sizeof buf, "/epoch_%03d.ins.u32", e);
        std::vector<uint32_t> inss = readU32(trace + buf);
        unsigned long long ir0, iw0;
        procIO(ir0, iw0);
        t0 = nowMs();
        long long insDone = 0;
        for (uint32_t g : inss) {
            if (g >= G || !haveVecAt(g)) continue;
            SizeType vid = -1;
            memcpy(scratch, gidVec(g), sizeof(VT) * dim);
            if (index->AddIndexSPFresh(scratch, 1, dim, &vid) != ErrorCode::Success) {
                fprintf(stderr, "[driver] insert failed gid=%u\n", g); continue;
            }
            if (vid >= (SizeType)vid2gid.size()) vid2gid.resize((size_t)vid + 1024, -1);
            gid2vid[g] = vid; vid2gid[vid] = g; isLive[g] = 1; insDone++;
        }
        while (!index->AllFinished()) std::this_thread::sleep_for(std::chrono::milliseconds(10));
        double tIns = nowMs() - t0;
        unsigned long long ir1, iw1;
        procIO(ir1, iw1);
        double insRdKb = insDone > 0 ? (ir1 - ir0) / 1024.0 / insDone : 0.0;
        double insWrKb = insDone > 0 ? (iw1 - iw0) / 1024.0 / insDone : 0.0;

        liveN += insDone - delDone;

        setEpoch(e);  // tag mem sampler for the (clean) query phase

        // ---- query phase: full query set, single thread, per-query latency ----
        std::vector<std::vector<int64_t>> resGids(qn);
        std::vector<double> lat(qn);
        unsigned long long qr0, qw0;
        procIO(qr0, qw0);
        double q0 = nowMs();
        for (int i = 0; i < qn; ++i) {
            QueryResult res(&qdata[(size_t)i * qd], ef, false);
            res.Reset();
            SPANN::SearchStats st;
            st.m_totalLatency = 0;
            double s = nowMs();
            index->GetMemoryIndex()->SearchIndex(res);
            index->SearchDiskIndex(res, &st);
            lat[i] = nowMs() - s;
            // results come back as a max-heap of `ef` candidates (NOT sorted);
            // sort ascending by distance and keep the K nearest.
            std::vector<std::pair<float, SizeType>> cand;
            cand.reserve(ef);
            for (int j = 0; j < ef; ++j) {
                auto* r = res.GetResult(j);
                if (r && r->VID >= 0) cand.emplace_back(r->Dist, r->VID);
            }
            std::sort(cand.begin(), cand.end());
            if (e == 0 && i == 0 && getenv("SPF_DEBUG")) {
                fprintf(stderr, "[dbg] q0 ncand=%zu top12 (vid:gid:dist):", cand.size());
                for (int j = 0; j < 12 && j < (int)cand.size(); ++j) {
                    SizeType v = cand[j].second;
                    fprintf(stderr, " %d:%lld:%.3f", (int)v, (v < (SizeType)vid2gid.size() ? vid2gid[v] : -1), cand[j].first);
                }
                fprintf(stderr, "\n");
            }
            auto& rg = resGids[i];
            for (int j = 0; j < K && j < (int)cand.size(); ++j) {
                SizeType v = cand[j].second;
                rg.push_back((v < (SizeType)vid2gid.size()) ? vid2gid[v] : -1);
            }
        }
        double qWall = (nowMs() - q0) / 1000.0;
        double qps = qWall > 0 ? qn / qWall : 0.0;
        unsigned long long qr1, qw1;
        procIO(qr1, qw1);
        double qryRdKb = qn > 0 ? (qr1 - qr0) / 1024.0 / qn : 0.0;

        std::vector<double> ls = lat; std::sort(ls.begin(), ls.end());
        double mean = 0; for (double x : ls) mean += x; mean /= (ls.empty() ? 1 : ls.size());
        auto pct = [&](double p) { return ls.empty() ? 0.0 : ls[std::min((size_t)(p * ls.size()), ls.size() - 1)]; };
        double p50 = pct(0.50), p99 = pct(0.99);

        // ---- recall@10 vs OUR gt100 (global ids), if checkpoint present ----
        snprintf(buf, sizeof buf, "/gt/epoch_%03d.gt100", e);
        uint32_t gnq = 0, gK = 0; std::vector<uint32_t> gids;
        bool haveGt = readGt(trace + buf, gnq, gK, gids);
        std::string recallStr = "null";
        if (haveGt && (int)gnq == qn) {
            double rsum = 0;
            for (int i = 0; i < qn; ++i) {
                std::set<int64_t> truth;
                for (int j = 0; j < 10 && j < (int)gK; ++j) truth.insert((int64_t)gids[(size_t)i * gK + j]);
                int hit = 0;
                for (int j = 0; j < 10 && j < (int)resGids[i].size(); ++j)
                    if (resGids[i][j] >= 0 && truth.count(resGids[i][j])) hit++;
                rsum += hit / 10.0;
            }
            char rb[32]; snprintf(rb, sizeof rb, "%.6f", rsum / qn); recallStr = rb;
        }

        // ---- sanity: did any currently-deleted id surface? ----
        for (int i = 0; i < qn; ++i)
            for (int j = 0; j < 10 && j < (int)resGids[i].size(); ++j) {
                int64_t g = resGids[i][j];
                if (g >= 0 && g < (int64_t)G && !isLive[g]) {
                    delAppearTotal++;
                    if (getenv("SPF_DEBUG") && delAppearTotal <= 12)
                        fprintf(stderr, "[dbg] LEAK epoch %d q%d rank%d gid=%lld vid=%lld\n",
                                e, i, j, g, gid2vid[g]);
                }
            }

        double insOps = tIns > 0 ? insDone / (tIns / 1000.0) : 0.0;
        double delOps = tDel > 0 ? delDone / (tDel / 1000.0) : 0.0;

        char line[768];
        snprintf(line, sizeof line,
            "{\"epoch\":%d,\"live_n\":%lld,\"recall10\":%s,\"qps\":%.2f,"
            "\"lat_mean_ms\":%.4f,\"lat_p50_ms\":%.4f,\"lat_p99_ms\":%.4f,"
            "\"ins_ops_s\":%.2f,\"del_ops_s\":%.2f,\"rss_mb\":%.2f,\"disk_mb\":%.2f,"
            "\"ins_read_kb_per_op\":%.2f,\"ins_write_kb_per_op\":%.2f,"
            "\"query_read_kb_per_q\":%.2f,\"rss_anon_mb\":%.2f,\"query_io_per_query\":0}\n",
            e, liveN, recallStr.c_str(), qps, mean, p50, p99,
            insOps, delOps, rssMb(), dirMb(kvPath), insRdKb, insWrKb, qryRdKb, rssAnonMb());
        jsonl << line; jsonl.flush();
        fprintf(stderr, "[driver] epoch %d live_n=%lld ins=%lld del=%lld recall=%s qps=%.1f p50=%.3fms p99=%.3fms\n",
                e, liveN, insDone, delDone, recallStr.c_str(), qps, p50, p99);

        // ---- iso-recall Pareto: query-only ef sweep at epoch 0 and the last epoch ----
        // (cross-system Pareto, plan §-must-do). Emits <out>.sweep.jsonl. Query-only: it
        // re-runs the query set at each ef WITHOUT touching the index. Restores ef after.
        if (haveGt && (int)gnq == qn && !sweepEfs.empty() && (e == 0 || e == nEpochs - 1)) {
            for (int sef : sweepEfs) {
                int useEf = std::max(sef, K);
                opts->m_searchInternalResultNum = useEf;
                std::vector<double> sl; sl.reserve(qn); double rs = 0;
                for (int i = 0; i < qn; ++i) {
                    QueryResult res(&qdata[(size_t)i * qd], useEf, false); res.Reset();
                    SPANN::SearchStats st; st.m_totalLatency = 0;
                    double s = nowMs();
                    index->GetMemoryIndex()->SearchIndex(res);
                    index->SearchDiskIndex(res, &st);
                    sl.push_back(nowMs() - s);
                    std::vector<std::pair<float, SizeType>> cand; cand.reserve(useEf);
                    for (int j = 0; j < useEf; ++j) { auto* r = res.GetResult(j); if (r && r->VID >= 0) cand.emplace_back(r->Dist, r->VID); }
                    std::sort(cand.begin(), cand.end());
                    std::set<int64_t> truth;
                    for (int j = 0; j < 10 && j < (int)gK; ++j) truth.insert((int64_t)gids[(size_t)i * gK + j]);
                    int hit = 0;
                    for (int j = 0; j < 10 && j < (int)cand.size(); ++j) {
                        SizeType v = cand[j].second;
                        int64_t g = (v < (SizeType)vid2gid.size()) ? vid2gid[v] : -1;
                        if (g >= 0 && truth.count(g)) hit++;
                    }
                    rs += hit / 10.0;
                }
                std::sort(sl.begin(), sl.end());
                double sm = 0; for (double x : sl) sm += x; sm /= (sl.empty() ? 1 : sl.size());
                sweepJs << "{\"epoch\":" << e << ",\"ef\":" << useEf
                        << ",\"recall10\":" << (rs / qn)
                        << ",\"lat_mean_ms\":" << sm
                        << ",\"lat_p99_ms\":" << (sl.empty() ? 0.0 : sl[std::min((size_t)(0.99 * sl.size()), sl.size() - 1)])
                        << ",\"live_n\":" << liveN << "}\n";
                sweepJs.flush();
            }
            opts->m_searchInternalResultNum = ef;  // restore
        }
    }

    index->ExitBlockController();
    jsonl.close();
    fprintf(stderr, "[driver] DONE. deleted-id-in-results count = %lld (want 0)\n", delAppearTotal);
    return 0;
}
