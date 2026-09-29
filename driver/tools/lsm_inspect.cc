// lsm_inspect: footprint attribution for an LSM-Vec graph DB (PVLDB revision, footprint study).
// Usage: lsm_inspect <db_dir> [varint]   (run after the benchmark process has exited)
// Prints on-disk file classes (SST / WAL / other) before opening, then per-CF LSM properties and,
// for the adjacency CF, live value bytes split into header / out-edges / in-edges.
#include <cstdio>
#include <filesystem>
#include <string>
#include <vector>
#include "rocksdb/graph.h"
using namespace ROCKSDB_NAMESPACE;
namespace fs = std::filesystem;

int main(int argc, char** argv) {
  if (argc < 2) { fprintf(stderr, "usage: lsm_inspect <db_dir>\n"); return 2; }
  std::string dir = argv[1];
  uint64_t sst = 0, wal = 0, other = 0; int nwal = 0;
  for (auto& e : fs::directory_iterator(dir)) {
    if (!e.is_regular_file()) continue;
    auto n = e.path().filename().string(); uint64_t sz = e.file_size();
    if (n.size() > 4 && n.substr(n.size() - 4) == ".sst") sst += sz;
    else if (n.size() > 4 && n.substr(n.size() - 4) == ".log" && n != "LOG") { wal += sz; nwal++; }
    else other += sz;
  }
  printf("files: sst=%.1fMB wal=%.1fMB (%d files) other=%.1fMB\n", sst / 1e6, wal / 1e6, nwal, other / 1e6);

  Options opts; opts.create_if_missing = false;
  const bool varint = argc > 2 && std::string(argv[2]) == "varint";
  RocksGraph g(opts, EDGE_UPDATE_EAGER, varint ? ENCODING_TYPE_VARINT : ENCODING_TYPE_NONE, /*reinit=*/false, dir);
  DB* db = g.get_raw_db();
  std::vector<std::string> cfs;
  DB::ListColumnFamilies(DBOptions(), dir, &cfs);
  // per-CF properties via the default + sa_tree handles; others aggregated
  auto prop = [&](ColumnFamilyHandle* h, const char* p) { uint64_t v = 0; db->GetIntProperty(h, p, &v); return v; };
  auto show = [&](const char* name, ColumnFamilyHandle* h) {
    printf("cf %-8s sst=%.1fMB live_est=%.1fMB keys_est=%llu memtable=%.1fMB",
           name, prop(h, "rocksdb.total-sst-files-size") / 1e6, prop(h, "rocksdb.estimate-live-data-size") / 1e6,
           (unsigned long long)prop(h, "rocksdb.estimate-num-keys"), prop(h, "rocksdb.cur-size-all-mem-tables") / 1e6);
    for (int l = 0; l < 7; ++l) {
      std::string v; db->GetProperty(h, "rocksdb.num-files-at-level" + std::to_string(l), &v);
      if (v != "0") printf(" L%d=%s", l, v.c_str());
    }
    printf("\n");
  };
  printf("column families:"); for (auto& c : cfs) printf(" %s", c.c_str()); printf("\n");
  show("adj", db->DefaultColumnFamily());
  if (g.sa_tree_cf()) show("sa_tree", g.sa_tree_cf());
  uint64_t agg = 0; db->GetAggregatedIntProperty("rocksdb.total-sst-files-size", &agg);
  printf("all-CF sst=%.1fMB\n", agg / 1e6);

  // live adjacency values: header / out / in bytes
  uint64_t n = 0, hdr = 0, outb = 0, inb = 0, keyb = 0, maxin = 0, outn = 0, inn = 0;
  auto* it = db->NewIterator(ReadOptions(), db->DefaultColumnFamily());
  for (it->SeekToFirst(); it->Valid(); it->Next()) {
    auto v = it->value(); if (v.size() < 8) continue;
    uint32_t o = *reinterpret_cast<const uint32_t*>(v.data());
    uint32_t i = *reinterpret_cast<const uint32_t*>(v.data() + 4);
    // payload bytes split by edge count (exact for fixed 8-byte ids; proportional for varint)
    const uint64_t pay = v.size() - 8, tot = uint64_t(o) + i;
    const uint64_t ob = tot ? pay * o / tot : 0;
    n++; keyb += it->key().size(); hdr += 8; outb += ob; inb += pay - ob;
    outn += o; inn += i; if (i > maxin) maxin = i;
  }
  delete it;
  printf("adj live: vertices=%llu keys=%.1fMB header=%.1fMB out=%.1fMB (avg %.1f) in=%.1fMB (avg %.1f, max %llu) "
         "total_live=%.1fMB\n", (unsigned long long)n, keyb / 1e6, hdr / 1e6, outb / 1e6, n ? (double)outn / n : 0,
         inb / 1e6, n ? (double)inn / n : 0, (unsigned long long)maxin, (keyb + hdr + outb + inb) / 1e6);
  return 0;
}
