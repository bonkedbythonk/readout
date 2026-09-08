// C ABI for the Rust metrics core (core/).
//
// Every call writes into caller-owned storage, so nothing here needs freeing
// except the sampler handle itself. The sampler holds the previous counters
// that turn the kernel's monotonic totals into rates.

#ifndef READOUT_CORE_H
#define READOUT_CORE_H

#include <stdint.h>

#define RO_MAX_CORES 64

typedef struct RoSampler RoSampler;

typedef struct {
    char model[64];
    char chip[128];
    char os_version[32];
    char os_build[32];
    char hostname[128];
    uint32_t performance_cores;
    uint32_t efficiency_cores;
    uint32_t logical_cores;
    uint64_t memory_bytes;
} RoHostInfo;

typedef struct {
    // Fractions in 0...1, averaged over the interval since the previous sample.
    double cpu_total;
    double cpu_user;
    double cpu_system;
    uint32_t core_count;
    double cores[RO_MAX_CORES];
    double load_average[3];
    uint64_t uptime_seconds;
    uint32_t process_count;

    // Bytes.
    uint64_t memory_total;
    uint64_t memory_used;       // app + wired + compressed, as in Activity Monitor
    uint64_t memory_app;
    uint64_t memory_wired;
    uint64_t memory_compressed;
    uint64_t memory_cached;
    uint64_t memory_free;
    double memory_pressure;           // (wired + compressed) / total
    uint32_t memory_pressure_level;   // 0 normal, 1 warning, 2 critical
    uint64_t swap_total;
    uint64_t swap_used;

    double network_rx_bytes_per_sec;
    double network_tx_bytes_per_sec;
    uint64_t network_rx_total;
    uint64_t network_tx_total;
} RoSnapshot;

typedef struct {
    char name[64];
    char mount_point[256];
    uint64_t total;
    uint64_t free_bytes;
    uint32_t is_root;
} RoVolume;

typedef struct {
    int32_t pid;
    char name[64];
    double cpu;        // share of one core; 2.0 means two cores fully busy
    uint64_t memory;   // resident bytes
    // Relative energy impact: CPU time weighted with idle wake-ups, the same
    // idea as Activity Monitor's Energy column. Deliberately not watts --
    // the kernel's per-process energy counter does not measure CPU power.
    double energy_impact;
} RoProcess;

// Ordering for ro_top_processes.
#define RO_SORT_CPU 0
#define RO_SORT_MEMORY 1
#define RO_SORT_ENERGY 2

uint32_t ro_abi_version(void);

RoSampler *ro_sampler_new(void);
void ro_sampler_free(RoSampler *sampler);

void ro_host_info(RoHostInfo *out);

// Cheap enough to call on a timer.
void ro_sample(RoSampler *sampler, RoSnapshot *out);

// Fills up to `capacity` entries; returns how many were written.
uint32_t ro_volumes(RoVolume *out, uint32_t capacity);

// Walks every process, so poll this less often than ro_sample.
uint32_t ro_top_processes(RoSampler *sampler, RoProcess *out, uint32_t capacity,
                          uint32_t sort);

#endif
