// Streaming-merge driver for the LSM vector benchmark (FreshDiskANN / DiskANN-merge,
// system name "diskann_merge"). Replays the shared benchmark trace (per-epoch global-id
// insert/delete lists) against a DiskANN v2 MergeInsert index:
//   * a disk-resident long-term Vamana+PQ index (built once from base.fbin), plus
//   * an in-memory short-term delta index that absorbs inserts/deletes, with
//   * a periodic StreamingMerge that folds the delta into the SSD index.
// Emits the per-epoch JSONL schema defined in docs/baseline_driver_spec.md.
//
// Tags == GLOBAL ids (we insert each vector under its global id), so delete lists and
// groundtruth match unambiguously and result tags are global ids directly.
//
// Merge cadence: FreshDiskANN merges every ~30M ops. We expose --merge_every <ops>;
// when cumulative in-memory inserts since the last merge reach it we call final_merge().
// At 1M scale with <1M ops the default (30M) never triggers -- expected & matches the paper.

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <numeric>
#include <sstream>
#include <string>
#include <sys/stat.h>
#include <dirent.h>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include <omp.h>

#include "aux_utils.h"
#include "distance.h"
#include "parameters.h"
#include "percentile_stats.h"
#include "utils.h"
#include "v2/merge_insert.h"

namespace
{
using clk = std::chrono::high_resolution_clock;

// .fbin : int32 n, int32 d, then n*d float32. Loaded with row stride aligned_dim (mult of 8).
float *load_fbin_aligned(const std::string &path, size_t &n, size_t &d, size_t &aligned_dim)
{
    std::ifstream in(path, std::ios::binary);
    if (!in)
        throw std::runtime_error("cannot open fbin: " + path);
    int32_t ni = 0, di = 0;
    in.read(reinterpret_cast<char *>(&ni), 4);
    in.read(reinterpret_cast<char *>(&di), 4);
    n = static_cast<size_t>(ni);
    d = static_cast<size_t>(di);
    aligned_dim = ROUND_UP(d, 8);
    float *buf = static_cast<float *>(std::calloc(n * aligned_dim, sizeof(float)));
    if (buf == nullptr)
        throw std::runtime_error("calloc failed for fbin: " + path);
    for (size_t i = 0; i < n; ++i)
        in.read(reinterpret_cast<char *>(buf + i * aligned_dim), d * sizeof(float));
    if (!in)
        throw std::runtime_error("short read on fbin: " + path);
    return buf;
}

std::vector<uint32_t> load_u32(const std::string &path)
{
    std::ifstream in(path, std::ios::binary | std::ios::ate);
    if (!in)
        return {};
    std::streamsize bytes = in.tellg();
    in.seekg(0);
    std::vector<uint32_t> v(static_cast<size_t>(bytes) / 4);
    if (!v.empty())
        in.read(reinterpret_cast<char *>(v.data()), static_cast<std::streamsize>(v.size() * 4));
    return v;
}

bool load_gt(const std::string &path, size_t &nq, size_t &K, std::vector<uint32_t> &ids)
{
    std::ifstream in(path, std::ios::binary);
    if (!in)
        return false;
    uint32_t nq32 = 0, k32 = 0;
    in.read(reinterpret_cast<char *>(&nq32), 4);
    in.read(reinterpret_cast<char *>(&k32), 4);
    if (!in)
        return false;
    nq = nq32;
    K = k32;
    ids.resize(nq * K);
    in.read(reinterpret_cast<char *>(ids.data()), static_cast<std::streamsize>(ids.size() * 4));
    return static_cast<bool>(in);
}

bool path_exists(const std::string &p)
{
    std::ifstream in(p);
    return static_cast<bool>(in);
}

std::string epoch_path(const std::string &dir, int epoch, const char *suffix)
{
    std::ostringstream os;
    os << dir << "/epoch_" << std::setw(3) << std::setfill('0') << epoch << suffix;
    return os.str();
}

long read_vmrss_kb()
{
    std::ifstream in("/proc/self/status");
    std::string line;
    while (std::getline(in, line))
        if (line.compare(0, 6, "VmRSS:") == 0)
        {
            std::istringstream is(line.substr(6));
            long kb = 0;
            is >> kb;
            return kb;
        }
    return 0;
}
double rss_mb()
{
    return read_vmrss_kb() / 1024.0;
}

double pctl(std::vector<double> &v, double p)
{
    if (v.empty())
        return 0.0;
    std::sort(v.begin(), v.end());
    size_t idx = static_cast<size_t>(p * (v.size() - 1) + 0.5);
    if (idx >= v.size())
        idx = v.size() - 1;
    return v[idx];
}

// sum of bytes of all files whose name starts with <prefix-basename>, in its dir
double dir_index_mb(const std::string &prefix)
{
    size_t slash = prefix.find_last_of('/');
    std::string dir = (slash == std::string::npos) ? "." : prefix.substr(0, slash);
    std::string base = (slash == std::string::npos) ? prefix : prefix.substr(slash + 1);
    double total = 0.0;
    std::string cmd; // avoid dirent boilerplate: stat the known suffixes
    const char *suffixes[] = {"_disk.index",        "_pq_compressed.bin", "_pq_pivots.bin",
                              "_disk.index.tags",    "_mem.index",         "_disk.index_medoids.bin",
                              "_disk.index_centroids.bin", "_sample_data.bin", "_sample_ids.bin"};
    for (const char *s : suffixes)
    {
        struct stat st;
        std::string f = prefix + s;
        if (stat(f.c_str(), &st) == 0)
            total += static_cast<double>(st.st_size);
    }
    (void)dir;
    (void)base;
    (void)cmd;
    return total / (1024.0 * 1024.0);
}

// ---- base-index snapshot/restore (skip the ~10-min disk build across merge_every sweeps) ----
// The base disk index is a pure function of (base vectors, R/L/alpha/B); merge_every only affects
// the epoch-phase merge cadence. So we cache the pristine base build in a snapshot dir and restore
// it on re-run. Snapshot is taken RIGHT AFTER build_disk_index (before any merge mutates the index).
void copy_file_bytes(const std::string &src, const std::string &dst)
{
    std::ifstream in(src, std::ios::binary);
    std::ofstream out(dst, std::ios::binary | std::ios::trunc);
    if (!in || !out)
        throw std::runtime_error("snapshot copy failed: " + src + " -> " + dst);
    out << in.rdbuf();
    if (!out)
        throw std::runtime_error("snapshot write short: " + dst);
}

// Files belonging to the base build: <prefix_base>* excluding runtime merge/mem working copies.
bool is_base_file(const std::string &name, const std::string &prefix_base)
{
    if (name.compare(0, prefix_base.size(), prefix_base) != 0)
        return false;
    if (name.find("_merge") != std::string::npos || name.find("_mem_short") != std::string::npos)
        return false;
    return true;
}

std::string path_dir(const std::string &p)
{
    size_t s = p.find_last_of('/');
    return (s == std::string::npos) ? "." : p.substr(0, s);
}
std::string path_base(const std::string &p)
{
    size_t s = p.find_last_of('/');
    return (s == std::string::npos) ? p : p.substr(s + 1);
}

// true if snap_dir holds a completed snapshot (sentinel present).
bool snapshot_ready(const std::string &snap_dir)
{
    struct stat st;
    return stat((snap_dir + "/SNAPSHOT_OK").c_str(), &st) == 0;
}

// Copy every base-build file for `index_prefix` into snap_dir, then drop the SNAPSHOT_OK sentinel.
void snapshot_base(const std::string &index_prefix, const std::string &snap_dir)
{
    mkdir(snap_dir.c_str(), 0755); // ok if it already exists
    const std::string src_dir = path_dir(index_prefix);
    const std::string pbase = path_base(index_prefix);
    DIR *d = opendir(src_dir.c_str());
    if (!d)
        throw std::runtime_error("snapshot: cannot open " + src_dir);
    struct dirent *e;
    int n = 0;
    while ((e = readdir(d)) != nullptr)
    {
        std::string name = e->d_name;
        if (is_base_file(name, pbase))
        {
            copy_file_bytes(src_dir + "/" + name, snap_dir + "/" + name);
            ++n;
        }
    }
    closedir(d);
    std::ofstream ok(snap_dir + "/SNAPSHOT_OK");
    ok << pbase << " " << n << "\n";
    std::cout << "base-index snapshot written: " << n << " files -> " << snap_dir << std::endl;
}

// Restore base-build files from snap_dir back next to index_prefix. Returns file count.
int restore_base(const std::string &index_prefix, const std::string &snap_dir)
{
    const std::string dst_dir = path_dir(index_prefix);
    mkdir(dst_dir.c_str(), 0755);
    DIR *d = opendir(snap_dir.c_str());
    if (!d)
        throw std::runtime_error("restore: cannot open " + snap_dir);
    struct dirent *e;
    int n = 0;
    while ((e = readdir(d)) != nullptr)
    {
        std::string name = e->d_name;
        if (name == "." || name == ".." || name == "SNAPSHOT_OK")
            continue;
        copy_file_bytes(snap_dir + "/" + name, dst_dir + "/" + name);
        ++n;
    }
    closedir(d);
    std::cout << "base-index restored from snapshot: " << n << " files <- " << snap_dir << std::endl;
    return n;
}

struct MemSampler
{
    std::ofstream out;
    std::atomic<bool> stop{false};
    std::atomic<int> epoch{-1};
    clk::time_point t0;
    std::thread th;
    void start(const std::string &path)
    {
        out.open(path);
        t0 = clk::now();
        th = std::thread([this]() {
            while (!stop.load())
            {
                double t = std::chrono::duration<double>(clk::now() - t0).count();
                out << "{\"t_sec\":" << std::fixed << std::setprecision(1) << t << ",\"epoch\":" << epoch.load()
                    << ",\"rss_mb\":" << std::setprecision(1) << rss_mb() << "}\n";
                out.flush();
                for (int i = 0; i < 10 && !stop.load(); ++i)
                    std::this_thread::sleep_for(std::chrono::milliseconds(100));
            }
        });
    }
    void finish()
    {
        stop.store(true);
        if (th.joinable())
            th.join();
        out.close();
    }
};
} // namespace

int main(int argc, char **argv)
{
    std::string trace, out_path, mem_path, index_prefix, work_dir;
    uint32_t search_L = 150;
    uint32_t R_mem = 64, L_mem = 75;
    uint32_t R_disk = 64, L_disk = 75;
    float alpha = 1.2f;
    uint32_t beamwidth = 2;
    int build_threads = 16;
    double B_gb = 0.0; // PQ RAM budget; 0 => auto-pick so num_pq_chunks == dim (near-lossless)
    double M_gb = 16.0;
    size_t merge_every = 10000;    // default merge window (project convention, 2026-07-05).
                                   // FreshDiskANN's own paper uses ~30M, but at 1M scale that never
                                   // fires; 10k makes merges actually happen so insert cost is real.
    size_t mem_capacity_th = 0;    // in-mem delta index sizing; 0 => auto (pool_n + headroom)
    std::string reuse_base_dir;    // --reuse_base_index <dir>: snapshot/restore base disk index to skip rebuild.
    uint32_t K = 10;

    for (int i = 1; i < argc; ++i)
    {
        std::string a = argv[i];
        auto next = [&]() { return std::string(argv[++i]); };
        if (a == "--trace")
            trace = next();
        else if (a == "--out")
            out_path = next();
        else if (a == "--mem")
            mem_path = next();
        else if (a == "--index_prefix")
            index_prefix = next();
        else if (a == "--work_dir")
            work_dir = next();
        else if (a == "--L")
            search_L = std::stoul(next());
        else if (a == "--R")
            R_mem = R_disk = std::stoul(next());
        else if (a == "--Lbuild")
            L_mem = L_disk = std::stoul(next());
        else if (a == "--alpha")
            alpha = std::stof(next());
        else if (a == "--beamwidth")
            beamwidth = std::stoul(next());
        else if (a == "--B_gb")
            B_gb = std::stod(next());
        else if (a == "--M_gb")
            M_gb = std::stod(next());
        else if (a == "--build_threads")
            build_threads = std::stoi(next());
        else if (a == "--merge_every")
            merge_every = std::stoull(next());
        else if (a == "--mem_capacity_th")
            mem_capacity_th = std::stoull(next());
        else if (a == "--reuse_base_index")
            reuse_base_dir = next();
        else
        {
            std::cerr << "unknown arg: " << a << std::endl;
            return 1;
        }
    }
    if (trace.empty() || out_path.empty() || mem_path.empty() || index_prefix.empty())
    {
        std::cerr << "usage: bench_stream_merge --trace <dir> --out <jsonl> --mem <memjsonl> "
                     "--index_prefix <prefix> [--work_dir <dir>] [--L 150] [--R 64] [--Lbuild 75] "
                     "[--alpha 1.2] [--beamwidth 2] [--B_gb 0(auto)] [--M_gb 16] [--build_threads 16] "
                     "[--merge_every 10000] [--mem_capacity_th 0(auto=pool_n)] "
                     "[--reuse_base_index <snapshot_dir>]\n";
        return 1;
    }
    if (work_dir.empty())
    {
        size_t slash = index_prefix.find_last_of('/');
        work_dir = (slash == std::string::npos) ? "." : index_prefix.substr(0, slash);
    }

    MemSampler mem;
    mem.start(mem_path);
    mem.epoch.store(-1); // build phase

    // ---- load base / pool / query (aligned) ----
    size_t base_n, dim, adim;
    float *base = load_fbin_aligned(trace + "/base.fbin", base_n, dim, adim);
    std::vector<uint32_t> base_ids = load_u32(trace + "/base.ids.u32");

    size_t pool_n, pdim, padim;
    float *pool = load_fbin_aligned(trace + "/pool.fbin", pool_n, pdim, padim);
    std::vector<uint32_t> pool_ids = load_u32(trace + "/pool.ids.u32");
    std::unordered_map<uint32_t, size_t> pool_index;
    pool_index.reserve(pool_n * 2);
    for (size_t i = 0; i < pool_n; ++i)
        pool_index[pool_ids[i]] = i;

    size_t q_n, qdim, qadim;
    float *query = load_fbin_aligned(trace + "/query.fbin", q_n, qdim, qadim);

    std::cout << "base_n=" << base_n << " dim=" << dim << " pool_n=" << pool_n << " q_n=" << q_n << std::endl;
    if (pdim != dim || qdim != dim)
    {
        std::cerr << "dimension mismatch between base/pool/query" << std::endl;
        return 1;
    }

    // ---- write the tags file (global ids) for the disk-index build ----
    std::string tags_file = index_prefix + ".base.tags";
    diskann::save_bin<uint32_t>(tags_file, base_ids.data(), base_n, 1);
    // base vectors are read from file by build_disk_index; the in-RAM copy is not needed
    // afterwards, so free it now to keep the reported RSS honest at scale.
    std::free(base);
    base = nullptr;

    // auto-pick B so num_pq_chunks == dim (near-lossless PQ) when not given.
    if (B_gb <= 0.0)
        B_gb = (static_cast<double>(dim) * static_cast<double>(base_n) * 1.05) / (1024.0 * 1024.0 * 1024.0);

    // ---- build (or restore) the disk-resident long-term index from base ----
    // The base index depends only on (base vectors, R/L/alpha/B) — NOT on merge_every. So when
    // --reuse_base_index <dir> points at a completed snapshot, restore it and skip the ~10-min build;
    // otherwise build once and populate the snapshot for future merge_every sweeps.
    std::ostringstream bparams;
    bparams << R_disk << " " << L_disk << " " << B_gb << " " << M_gb << " " << build_threads;
    double build_s = 0.0;
    bool restored = !reuse_base_dir.empty() && snapshot_ready(reuse_base_dir);
    if (restored)
    {
        std::cout << "reusing base disk index (skipping build) from " << reuse_base_dir << std::endl;
        auto rt0 = clk::now();
        restore_base(index_prefix, reuse_base_dir);
        build_s = std::chrono::duration<double>(clk::now() - rt0).count();
        std::cout << "base index restore done in " << build_s << "s (build skipped)" << std::endl;
    }
    else
    {
        std::cout << "building disk index: prefix=" << index_prefix << " params=[" << bparams.str() << "]" << std::endl;
        auto build_t0 = clk::now();
        bool ok = diskann::build_disk_index<float>((trace + "/base.fbin").c_str(), index_prefix.c_str(),
                                                   bparams.str().c_str(), diskann::Metric::L2,
                                                   /*single_file_index=*/false, tags_file.c_str());
        if (!ok)
        {
            std::cerr << "disk index build FAILED" << std::endl;
            return 1;
        }
        build_s = std::chrono::duration<double>(clk::now() - build_t0).count();
        std::cout << "disk index build done in " << build_s << "s" << std::endl;
        // snapshot the pristine base NOW, before MergeInsert / any merge can mutate it.
        if (!reuse_base_dir.empty())
            snapshot_base(index_prefix, reuse_base_dir);
    }

    // ---- construct MergeInsert (in-mem delta + disk index + StreamingMerge) ----
    diskann::Parameters paras;
    paras.Set<unsigned>("L_mem", L_mem);
    paras.Set<unsigned>("R_mem", R_mem);
    paras.Set<float>("alpha_mem", alpha);
    paras.Set<unsigned>("L_disk", L_disk);
    paras.Set<unsigned>("R_disk", R_disk);
    paras.Set<float>("alpha_disk", alpha);
    paras.Set<unsigned>("C", 75);
    paras.Set<unsigned>("beamwidth", beamwidth);
    paras.Set<unsigned>("nodes_to_cache", 0);
    paras.Set<unsigned>("num_search_threads", std::max<int>(build_threads, 2));

    diskann::DistanceL2 dist_cmp;
    std::string mem_prefix = index_prefix + "_mem_short";
    std::string merge_prefix = index_prefix + "_merge";
    // Mem-index capacity is sized as merge_th*2. Default to pool_n (+headroom) so the empty
    // pre-allocation matches the run scale instead of the upstream 30M default (which would
    // reserve ~60GB at dim=128). The StreamingMerge cadence itself is driven by --merge_every.
    if (mem_capacity_th == 0)
        mem_capacity_th = pool_n + 1000;
    std::cout << "mem_capacity_th=" << mem_capacity_th << " (mem-index capacity=" << (mem_capacity_th * 2) << " pts)"
              << std::endl;
    diskann::MergeInsert<float, uint32_t> sync_index(paras, dim, mem_prefix, index_prefix, merge_prefix, &dist_cmp,
                                                     diskann::Metric::L2, /*single_file=*/false, work_dir,
                                                     mem_capacity_th);

    std::ofstream jout(out_path);
    jout << std::fixed;

    long long live_n = static_cast<long long>(base_n);
    std::unordered_set<uint32_t> deleted_ids;
    size_t delete_violations = 0;
    size_t ops_since_merge = 0;
    int merge_count = 0;

    int n_epochs = 0;
    while (path_exists(epoch_path(trace, n_epochs, ".ins.u32")) || path_exists(epoch_path(trace, n_epochs, ".del.u32")))
        ++n_epochs;
    std::cout << "n_epochs=" << n_epochs << " merge_every=" << merge_every << std::endl;

    for (int e = 0; e < n_epochs; ++e)
    {
        mem.epoch.store(e);
        std::vector<uint32_t> ins = load_u32(epoch_path(trace, e, ".ins.u32"));
        std::vector<uint32_t> del = load_u32(epoch_path(trace, e, ".del.u32"));

        // ---- apply phase: deletes then inserts (single-thread; MergeInsert is the system) ----
        auto del_t0 = clk::now();
        for (uint32_t gid : del)
        {
            sync_index.lazy_delete(gid);
            deleted_ids.insert(gid);
        }
        double del_s = std::chrono::duration<double>(clk::now() - del_t0).count();

        auto ins_t0 = clk::now();
        for (uint32_t gid : ins)
        {
            auto it = pool_index.find(gid);
            if (it == pool_index.end())
                continue;
            sync_index.insert(pool + it->second * padim, gid);
            deleted_ids.erase(gid);
        }
        double ins_s = std::chrono::duration<double>(clk::now() - ins_t0).count();

        live_n += static_cast<long long>(ins.size()) - static_cast<long long>(del.size());
        ops_since_merge += ins.size();

        // ---- StreamingMerge per FreshDiskANN cadence ----
        if (ops_since_merge >= merge_every)
        {
            std::cout << "epoch " << e << ": triggering StreamingMerge (ops_since_merge=" << ops_since_merge << ")"
                      << std::endl;
            sync_index.final_merge();
            ops_since_merge = 0;
            ++merge_count;
            deleted_ids.clear(); // merged-out deletes are now physically gone from the SSD index
        }

        // ---- query phase (single-threaded for clean per-query latency) ----
        std::ostringstream gtos;
        gtos << trace << "/gt/epoch_" << std::setw(3) << std::setfill('0') << e << ".gt100";
        size_t gt_nq = 0, gt_K = 0;
        std::vector<uint32_t> gt_ids;
        bool have_gt = load_gt(gtos.str(), gt_nq, gt_K, gt_ids);

        std::vector<double> lat_ms;
        lat_ms.reserve(q_n);
        std::vector<uint32_t> tags(K);
        std::vector<float> dists(K);
        double recall_sum = 0.0;
        size_t recall_q = 0;

        auto qphase_t0 = clk::now();
        for (size_t qi = 0; qi < q_n; ++qi)
        {
            diskann::QueryStats stats;
            stats.n_current_used = 1e9; // never short-circuit the in-mem delta search on a time budget
            for (uint32_t r = 0; r < K; ++r)
            {
                tags[r] = std::numeric_limits<uint32_t>::max();
                dists[r] = std::numeric_limits<float>::max();
            }
            auto t0 = clk::now();
            sync_index.search_sync(query + qi * qadim, K, search_L, tags.data(), dists.data(), &stats);
            double ms = std::chrono::duration<double, std::milli>(clk::now() - t0).count();
            lat_ms.push_back(ms);

            std::unordered_set<uint32_t> truth;
            size_t topk = std::min<size_t>(K, gt_K);
            if (have_gt)
                for (size_t r = 0; r < topk; ++r)
                    truth.insert(gt_ids[qi * gt_K + r]);
            size_t hit = 0;
            for (uint32_t r = 0; r < K; ++r)
            {
                uint32_t gid = tags[r];
                if (gid == std::numeric_limits<uint32_t>::max())
                    continue;
                if (deleted_ids.count(gid))
                    ++delete_violations;
                if (have_gt && truth.count(gid))
                    ++hit;
            }
            if (have_gt)
            {
                recall_sum += static_cast<double>(hit) / static_cast<double>(topk);
                ++recall_q;
            }
        }
        double qphase_s = std::chrono::duration<double>(clk::now() - qphase_t0).count();

        double mean_ms = std::accumulate(lat_ms.begin(), lat_ms.end(), 0.0) / std::max<size_t>(lat_ms.size(), 1);
        double p50 = pctl(lat_ms, 0.50);
        double p99 = pctl(lat_ms, 0.99);
        double qps = q_n / std::max(qphase_s, 1e-9);
        double ins_ops_s = ins.empty() ? 0.0 : ins.size() / std::max(ins_s, 1e-9);
        double del_ops_s = del.empty() ? 0.0 : del.size() / std::max(del_s, 1e-9);
        double disk_mb = dir_index_mb(sync_index.ret_merge_prefix());

        jout << "{\"epoch\":" << e << ",\"live_n\":" << live_n << ",\"recall10\":";
        if (have_gt)
            jout << std::setprecision(4) << (recall_sum / std::max<size_t>(recall_q, 1));
        else
            jout << "null";
        jout << ",\"qps\":" << std::setprecision(2) << qps << ",\"lat_mean_ms\":" << std::setprecision(3) << mean_ms
             << ",\"lat_p50_ms\":" << p50 << ",\"lat_p99_ms\":" << p99 << ",\"ins_ops_s\":" << std::setprecision(2)
             << ins_ops_s << ",\"del_ops_s\":" << del_ops_s << ",\"rss_mb\":" << std::setprecision(1) << rss_mb()
             << ",\"disk_mb\":" << disk_mb << ",\"query_io_per_query\":" << 0 << "}\n";
        jout.flush();

        std::cout << "epoch " << e << " live_n=" << live_n
                  << " recall10=" << (have_gt ? std::to_string(recall_sum / std::max<size_t>(recall_q, 1)) : "null")
                  << " qps=" << qps << " p50=" << p50 << "ms p99=" << p99 << "ms disk_mb=" << disk_mb << std::endl;
    }

    jout.close();
    mem.finish();
    std::cout << "DONE. merges=" << merge_count << " deleted-id violations in results: " << delete_violations
              << " (expect 0). final live_n=" << live_n << std::endl;

    std::free(pool);
    std::free(query);
    return delete_violations == 0 ? 0 : 2;
}
