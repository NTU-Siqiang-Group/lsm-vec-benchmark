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
#include <string>
#include <vector>
#include <set>
#include <algorithm>
#include <chrono>
#include <fstream>
#include <filesystem>
#include <thread>

#include "inc/Core/Common.h"
#include "inc/Core/VectorIndex.h"
#include "inc/Core/SPANN/Index.h"
#include "inc/Core/SearchQuery.h"

using namespace SPTAG;
namespace fs = std::filesystem;

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
static bool readFbin(const std::string& path, int32_t& n, int32_t& d, std::vector<float>& data) {
    std::ifstream f(path, std::ios::binary);
    if (!f) return false;
    f.read((char*)&n, 4); f.read((char*)&d, 4);
    data.resize((size_t)n * d);
    f.read((char*)data.data(), (std::streamsize)data.size() * 4);
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
    if (vindex->GetVectorValueType() != VectorValueType::Float) {
        fprintf(stderr, "FATAL: driver supports Float vectors only\n");
        return 1;
    }
    auto* index = static_cast<SPANN::Index<float>*>(vindex.get());
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

    // ---- load base+pool vectors into a global-id-indexed array ----
    int32_t bn, bd, pn = 0, pd = 0;
    std::vector<float> bdata, pdata;
    if (!readFbin(trace + "/base.fbin", bn, bd, bdata)) { fprintf(stderr, "FATAL: base.fbin\n"); return 1; }
    readFbin(trace + "/pool.fbin", pn, pd, pdata);  // pool may be absent for pure builds
    std::vector<uint32_t> bids = readU32(trace + "/base.ids.u32");
    std::vector<uint32_t> pids = readU32(trace + "/pool.ids.u32");
    if ((int)bids.size() != bn) { fprintf(stderr, "FATAL: base ids/vec mismatch\n"); return 1; }

    uint32_t maxGid = 0;
    for (auto g : bids) maxGid = std::max(maxGid, g);
    for (auto g : pids) maxGid = std::max(maxGid, g);
    size_t G = (size_t)maxGid + 1;
    std::vector<float> vec((size_t)G * dim, 0.f);
    std::vector<char> haveVec(G, 0);
    for (int i = 0; i < bn; ++i) { uint32_t g = bids[i]; memcpy(&vec[(size_t)g * dim], &bdata[(size_t)i * bd], sizeof(float) * dim); haveVec[g] = 1; }
    for (int i = 0; i < pn; ++i) { uint32_t g = pids[i]; memcpy(&vec[(size_t)g * dim], &pdata[(size_t)i * pd], sizeof(float) * dim); haveVec[g] = 1; }

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
    int32_t qn, qd; std::vector<float> qdata;
    if (!readFbin(trace + "/query.fbin", qn, qd, qdata)) { fprintf(stderr, "FATAL: query.fbin\n"); return 1; }

    index->Initialize();  // init RocksDB block/searcher resources

    std::ofstream jsonl(out, std::ios::trunc);
    auto nowMs = [] { return std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now().time_since_epoch()).count(); };

    long long delAppearTotal = 0;  // sanity: deleted ids surfacing in results

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
        t0 = nowMs();
        long long insDone = 0;
        for (uint32_t g : inss) {
            if (g >= G || !haveVec[g]) continue;
            SizeType vid = -1;
            if (index->AddIndexSPFresh(&vec[(size_t)g * dim], 1, dim, &vid) != ErrorCode::Success) {
                fprintf(stderr, "[driver] insert failed gid=%u\n", g); continue;
            }
            if (vid >= (SizeType)vid2gid.size()) vid2gid.resize((size_t)vid + 1024, -1);
            gid2vid[g] = vid; vid2gid[vid] = g; isLive[g] = 1; insDone++;
        }
        while (!index->AllFinished()) std::this_thread::sleep_for(std::chrono::milliseconds(10));
        double tIns = nowMs() - t0;

        liveN += insDone - delDone;

        setEpoch(e);  // tag mem sampler for the (clean) query phase

        // ---- query phase: full query set, single thread, per-query latency ----
        std::vector<std::vector<int64_t>> resGids(qn);
        std::vector<double> lat(qn);
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

        char line[512];
        snprintf(line, sizeof line,
            "{\"epoch\":%d,\"live_n\":%lld,\"recall10\":%s,\"qps\":%.2f,"
            "\"lat_mean_ms\":%.4f,\"lat_p50_ms\":%.4f,\"lat_p99_ms\":%.4f,"
            "\"ins_ops_s\":%.2f,\"del_ops_s\":%.2f,\"rss_mb\":%.2f,\"disk_mb\":%.2f,"
            "\"query_io_per_query\":0}\n",
            e, liveN, recallStr.c_str(), qps, mean, p50, p99,
            insOps, delOps, rssMb(), dirMb(kvPath));
        jsonl << line; jsonl.flush();
        fprintf(stderr, "[driver] epoch %d live_n=%lld ins=%lld del=%lld recall=%s qps=%.1f p50=%.3fms p99=%.3fms\n",
                e, liveN, insDone, delDone, recallStr.c_str(), qps, p50, p99);
    }

    index->ExitBlockController();
    jsonl.close();
    fprintf(stderr, "[driver] DONE. deleted-id-in-results count = %lld (want 0)\n", delAppearTotal);
    return 0;
}
