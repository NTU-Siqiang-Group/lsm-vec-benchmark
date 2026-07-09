// Custom streaming driver for the LSM vector benchmark (DiskANN in-place / "diskann_ip").
// Replays the shared benchmark trace (arbitrary per-epoch insert/delete global-id lists)
// against a DiskANN dynamic in-memory index and emits the per-epoch JSONL schema defined
// in docs/baseline_driver_spec.md.
//
// NOTE: DiskANN reserves tag 0 for hidden/frozen points, so every global id `g` is stored
// under tag `g + 1`; results are mapped back by subtracting 1.

#include <atomic>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <map>
#include <numeric>
#include <sstream>
#include <string>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include <omp.h>

#include <abstract_index.h>
#include <index.h>
#include <index_factory.h>

#include "utils.h"

namespace
{
using clk = std::chrono::high_resolution_clock;

// ---- simple binary readers -------------------------------------------------

// .fbin : int32 n, int32 d, then n*d float32 (row-major).
// Loads into a freshly malloc'd buffer with row stride = aligned_dim (>= d, multiple of 8),
// zero-padded. Caller owns the buffer (free()).
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

// .u32 : raw little-endian uint32 array, no header (length = filesize/4).
std::vector<uint32_t> load_u32(const std::string &path)
{
    std::ifstream in(path, std::ios::binary | std::ios::ate);
    if (!in)
        return {}; // missing file -> empty
    std::streamsize bytes = in.tellg();
    in.seekg(0);
    std::vector<uint32_t> v(static_cast<size_t>(bytes) / 4);
    if (!v.empty())
        in.read(reinterpret_cast<char *>(v.data()), static_cast<std::streamsize>(v.size() * 4));
    return v;
}

// .gt100 : uint32 nq, uint32 K, then nq*K uint32 ids, then nq*K float32 dists.
// Returns ids (we only need the neighbor global ids).
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
    {
        if (line.compare(0, 6, "VmRSS:") == 0)
        {
            std::istringstream is(line.substr(6));
            long kb = 0;
            is >> kb;
            return kb;
        }
    }
    return 0;
}

double rss_mb()
{
    return read_vmrss_kb() / 1024.0;
}

double pctl(std::vector<double> &v, double p) // v in ms, will be sorted
{
    if (v.empty())
        return 0.0;
    std::sort(v.begin(), v.end());
    size_t idx = static_cast<size_t>(p * (v.size() - 1) + 0.5);
    if (idx >= v.size())
        idx = v.size() - 1;
    return v[idx];
}

// background RSS sampler
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
    std::string trace, out_path, mem_path;
    uint32_t search_L = 150;
    uint32_t R = 64, L_build = 75;
    float alpha = 1.2f;
    int insert_threads = 16;
    size_t max_points = 1500000;
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
        else if (a == "--L")
            search_L = std::stoul(next());
        else if (a == "--R")
            R = std::stoul(next());
        else if (a == "--Lbuild")
            L_build = std::stoul(next());
        else if (a == "--alpha")
            alpha = std::stof(next());
        else if (a == "--insert_threads")
            insert_threads = std::stoi(next());
        else if (a == "--max_points")
            max_points = std::stoull(next());
        else
        {
            std::cerr << "unknown arg: " << a << std::endl;
            return 1;
        }
    }
    if (trace.empty() || out_path.empty() || mem_path.empty())
    {
        std::cerr << "usage: bench_stream_diskann --trace <dir> --out <jsonl> --mem <memjsonl> "
                     "[--L <searchL>] [--R 64] [--Lbuild 75] [--alpha 1.2] [--insert_threads 16] [--max_points N]\n";
        return 1;
    }

    MemSampler mem;
    mem.start(mem_path);
    mem.epoch.store(-1); // base build phase

    // ---- load base / pool / query ----
    size_t base_n, dim, adim;
    float *base = load_fbin_aligned(trace + "/base.fbin", base_n, dim, adim);
    std::vector<uint32_t> base_ids = load_u32(trace + "/base.ids.u32");

    size_t pool_n, pdim, padim;
    float *pool = load_fbin_aligned(trace + "/pool.fbin", pool_n, pdim, padim);
    std::vector<uint32_t> pool_ids = load_u32(trace + "/pool.ids.u32");
    std::unordered_map<uint32_t, size_t> pool_index; // global id -> row in pool
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

    // start-point norm = mean L2 norm of a sample of base vectors (so the frozen start
    // point sits in the data cloud rather than at the origin).
    double norm_sum = 0.0;
    size_t norm_cnt = std::min<size_t>(base_n, 10000);
    for (size_t i = 0; i < norm_cnt; ++i)
    {
        const float *v = base + i * adim;
        double s = 0;
        for (size_t j = 0; j < dim; ++j)
            s += static_cast<double>(v[j]) * v[j];
        norm_sum += std::sqrt(s);
    }
    float start_norm = static_cast<float>(norm_sum / std::max<size_t>(norm_cnt, 1));
    if (start_norm <= 0.f)
        start_norm = 1.f;

    // ---- build dynamic index ----
    diskann::IndexWriteParameters write_params = diskann::IndexWriteParametersBuilder(L_build, R)
                                                     .with_max_occlusion_size(500)
                                                     .with_alpha(alpha)
                                                     .with_saturate_graph(false)
                                                     .with_num_threads(insert_threads)
                                                     .build();
    auto search_params = diskann::IndexSearchParams(std::max(search_L, L_build), insert_threads);

    auto cfg = diskann::IndexConfigBuilder()
                   .with_metric(diskann::L2)
                   .with_dimension(dim)
                   .with_max_points(max_points)
                   .is_dynamic_index(true)
                   .is_enable_tags(true)
                   .is_use_opq(false)
                   .is_filtered(false)
                   .with_num_pq_chunks(0)
                   .is_pq_dist_build(false)
                   .with_num_frozen_pts(1)
                   .with_tag_type(diskann_type_to_name<uint32_t>())
                   .with_label_type(diskann_type_to_name<uint32_t>())
                   .with_data_type(diskann_type_to_name<float>())
                   .with_index_write_params(write_params)
                   .with_index_search_params(search_params)
                   .with_data_load_store_strategy(diskann::DataStoreStrategy::MEMORY)
                   .with_graph_load_store_strategy(diskann::GraphStoreStrategy::MEMORY)
                   .build();

    diskann::IndexFactory factory(cfg);
    auto index = factory.create_instance();
    index->set_start_points_at_random(start_norm);

    std::cout << "building initial index over " << base_n << " base vectors (start_norm=" << start_norm << ")..."
              << std::endl;
    auto build_t0 = clk::now();
#pragma omp parallel for num_threads(insert_threads) schedule(dynamic)
    for (int64_t i = 0; i < static_cast<int64_t>(base_n); ++i)
    {
        uint32_t tag = base_ids[i] + 1; // tag 0 reserved
        index->insert_point<float, uint32_t>(base + i * adim, tag);
    }
    double build_s = std::chrono::duration<double>(clk::now() - build_t0).count();
    std::cout << "initial build done in " << build_s << "s" << std::endl;
    // delete is auto-enabled for dynamic index in its constructor.

    diskann::IndexWriteParameters del_params = diskann::IndexWriteParametersBuilder(L_build, R)
                                                   .with_max_occlusion_size(500)
                                                   .with_alpha(alpha)
                                                   .with_saturate_graph(false)
                                                   .with_num_threads(insert_threads)
                                                   .build();

    std::ofstream jout(out_path);
    jout << std::fixed;

    // live-set accounting + cumulative deleted-id set (for sanity gate b)
    long long live_n = static_cast<long long>(base_n);
    std::unordered_set<uint32_t> deleted_ids;   // global ids currently absent (deleted, not re-inserted)
    size_t delete_violations = 0;

    // discover number of epochs
    int n_epochs = 0;
    while (path_exists(epoch_path(trace, n_epochs, ".ins.u32")) ||
           path_exists(epoch_path(trace, n_epochs, ".del.u32")))
        ++n_epochs;
    std::cout << "n_epochs=" << n_epochs << std::endl;

    for (int e = 0; e < n_epochs; ++e)
    {
        mem.epoch.store(e);
        std::vector<uint32_t> ins = load_u32(epoch_path(trace, e, ".ins.u32"));
        std::vector<uint32_t> del = load_u32(epoch_path(trace, e, ".del.u32"));

        // ---- apply phase: deletes then inserts (sequential like the spec) ----
        auto del_t0 = clk::now();
        for (uint32_t gid : del)
        {
            index->lazy_delete<uint32_t>(gid + 1);
            deleted_ids.insert(gid);
        }
        if (!del.empty())
        {
            auto rep = index->consolidate_deletes(del_params);
            while (rep._status != diskann::consolidation_report::status_code::SUCCESS)
            {
                std::this_thread::sleep_for(std::chrono::seconds(1));
                rep = index->consolidate_deletes(del_params);
            }
        }
        double del_s = std::chrono::duration<double>(clk::now() - del_t0).count();

        auto ins_t0 = clk::now();
#pragma omp parallel for num_threads(insert_threads) schedule(dynamic)
        for (int64_t i = 0; i < static_cast<int64_t>(ins.size()); ++i)
        {
            uint32_t gid = ins[i];
            auto it = pool_index.find(gid);
            if (it == pool_index.end())
                continue;
            index->insert_point<float, uint32_t>(pool + it->second * padim, gid + 1);
        }
        double ins_s = std::chrono::duration<double>(clk::now() - ins_t0).count();
        for (uint32_t gid : ins)
            deleted_ids.erase(gid); // re-inserted ids are live again

        live_n += static_cast<long long>(ins.size()) - static_cast<long long>(del.size());

        // ---- query phase (single-threaded for clean per-query latency) ----
        std::ostringstream gtos;
        gtos << trace << "/gt/epoch_" << std::setw(3) << std::setfill('0') << e << ".gt100";
        std::string gtp = gtos.str();
        size_t gt_nq = 0, gt_K = 0;
        std::vector<uint32_t> gt_ids;
        bool have_gt = load_gt(gtp, gt_nq, gt_K, gt_ids);

        std::vector<double> lat_ms;
        lat_ms.reserve(q_n);
        std::vector<uint32_t> tags(K);
        std::vector<float> dists(K);
        std::vector<float *> res_vectors; // empty: we only want tags
        double recall_sum = 0.0;
        size_t recall_q = 0;

        auto qphase_t0 = clk::now();
        for (size_t qi = 0; qi < q_n; ++qi)
        {
            auto t0 = clk::now();
            size_t got = index->search_with_tags<float, uint32_t>(query + qi * qadim, K, search_L, tags.data(),
                                                                  dists.data(), res_vectors);
            double ms = std::chrono::duration<double, std::milli>(clk::now() - t0).count();
            lat_ms.push_back(ms);

            // map tags back to global ids; sanity-check deleted ids never appear
            for (size_t r = 0; r < got; ++r)
            {
                uint32_t gid = tags[r] - 1;
                if (deleted_ids.count(gid))
                    ++delete_violations;
            }

            if (have_gt)
            {
                // intersection of result top-K with gt top-K (=10)
                std::unordered_set<uint32_t> truth;
                size_t topk = std::min<size_t>(K, gt_K);
                for (size_t r = 0; r < topk; ++r)
                    truth.insert(gt_ids[qi * gt_K + r]);
                size_t hit = 0;
                for (size_t r = 0; r < got; ++r)
                    if (truth.count(tags[r] - 1))
                        ++hit;
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

        jout << "{\"epoch\":" << e << ",\"live_n\":" << live_n << ",\"recall10\":";
        if (have_gt)
            jout << std::setprecision(4) << (recall_sum / std::max<size_t>(recall_q, 1));
        else
            jout << "null";
        jout << ",\"qps\":" << std::setprecision(2) << qps << ",\"lat_mean_ms\":" << std::setprecision(3) << mean_ms
             << ",\"lat_p50_ms\":" << p50 << ",\"lat_p99_ms\":" << p99 << ",\"ins_ops_s\":" << std::setprecision(2)
             << ins_ops_s << ",\"del_ops_s\":" << del_ops_s << ",\"rss_mb\":" << std::setprecision(1) << rss_mb()
             << ",\"disk_mb\":" << 0.0 << ",\"query_io_per_query\":" << 0 << "}\n";
        jout.flush();

        std::cout << "epoch " << e << " live_n=" << live_n << " recall10="
                  << (have_gt ? std::to_string(recall_sum / std::max<size_t>(recall_q, 1)) : std::string("null"))
                  << " qps=" << qps << " p50=" << p50 << "ms p99=" << p99 << "ms ins_s=" << ins_s << " del_s=" << del_s
                  << std::endl;
    }

    jout.close();
    mem.finish();

    std::cout << "DONE. deleted-id violations in results: " << delete_violations
              << " (expect 0). final live_n=" << live_n << std::endl;

    std::free(base);
    std::free(pool);
    std::free(query);
    return delete_violations == 0 ? 0 : 2;
}
