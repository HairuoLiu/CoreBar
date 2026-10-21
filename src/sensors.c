// sensors.c — native Apple Silicon GPU load + temperature sampling.
//
// Replaces the `macmon pipe` child process (Rust) with pure C so the app has
// zero subprocess overhead and ~9 MiB less footprint. Two private-ish sources:
//
//   * GPU load  : IOReport ("GPU Stats" / "GPU Performance States"), loaded
//                from /usr/lib/libIOReport.dylib at runtime because the SDK
//                does not ship IOReport.h. We mirror macmon's exact algorithm:
//                subscription -> two samples -> delta -> GPUPH channel residencies
//                -> scaled ratio (active residency weighted by the GPU DVFS table).
//   * Temperature: SMC "flt "-typed Tp*/Te*/Ts* (CPU) and Tg* (GPU) keys when
//                exposed (macOS 14+), enumerated exactly like macmon: #KEY
//                count -> key_by_index -> prefix match -> flt/4 check -> read.
//                On machines without SMC temperature keys we fall back to the
//                IOHID thermal sensor service (PrimaryUsagePage 0xff00 /
//                Usage 0x5), the same source macmon uses as its fallback.
//
// CPU %, per-core and memory are already sampled natively in Swift; this module
// only covers the two things macmon used to ship over the pipe. No Python.
#include "sensors.h"

#include <dlfcn.h>
#include <string.h>
#include <strings.h>
#include <stdlib.h>
#include <stdint.h>
#include <math.h>
#include <unistd.h>
#include <mach/mach.h>
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>

// ---------------------------------------------------------------------------
// IOReport (dlopen; SDK header absent from Command Line Tools).
// Signatures verified against reverse-engineered IOReport.h (NeoAsitop / OSHI).
// ---------------------------------------------------------------------------
typedef CFDictionaryRef (*CopyChannelsFn)(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
typedef CFTypeRef       (*CreateSubscriptionFn)(void *, CFMutableDictionaryRef,
                                                 CFMutableDictionaryRef *, uint64_t, CFTypeRef);
typedef CFTypeRef       (*CreateSamplesFn)(CFTypeRef, CFMutableDictionaryRef, CFTypeRef);
typedef CFTypeRef       (*CreateSamplesDeltaFn)(CFTypeRef, CFTypeRef, CFTypeRef);
typedef CFIndex         (*StateGetCountFn)(CFTypeRef);
typedef CFStringRef     (*StateGetNameFn)(CFTypeRef, CFIndex);
typedef int64_t         (*StateGetResidencyFn)(CFTypeRef, CFIndex);
typedef CFStringRef     (*ChannelGetNameFn)(CFTypeRef);

static void                   *g_ioreport = NULL;
static CopyChannelsFn         g_copyChannels = NULL;
static CreateSubscriptionFn   g_createSub = NULL;
static CreateSamplesFn        g_createSamples = NULL;
static CreateSamplesDeltaFn   g_samplesDelta = NULL;
static StateGetCountFn        g_stateCount = NULL;
static StateGetNameFn         g_stateName = NULL;
static StateGetResidencyFn    g_stateRes = NULL;
static ChannelGetNameFn       g_chanName = NULL;

static CFTypeRef              g_subs = NULL;        // IOReportSubscriptionRef (owned)
static CFMutableDictionaryRef g_chan = NULL;        // desired channels (owned)
static CFMutableDictionaryRef g_subbed = NULL;      // subscribed channels (owned)
static CFTypeRef              g_samplePrev = NULL;  // retained previous sample

// GPU DVFS frequency table (raw values; only used as a ratio, so Hz vs kHz cancels).
static uint32_t              *g_gpuFreqs = NULL;
static int                    g_gpuFreqCount = 0;

// ---------------------------------------------------------------------------
// SMC (used only when temperature keys are exposed as "flt " floats)
// ---------------------------------------------------------------------------
typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } SMCKeyDataVer;
typedef struct { uint16_t version, length; uint32_t cpu, gpu, mem; } SMCPlimit;
typedef struct { uint32_t data_size; uint32_t data_type; uint8_t data_attr; uint8_t _pad[3]; } SMCKeyInfo;
typedef struct {
    uint32_t      key;        // FourCC, big-endian (e.g. "Tp0S" = 0x54703053)
    SMCKeyDataVer vers;
    SMCPlimit     plimit;
    SMCKeyInfo    kinfo;
    uint8_t       result;     // 0 == success, 132 == key not found
    uint8_t       status;
    uint8_t       data8;      // sub-command: 5 read, 9 key-info, 8 index
    uint8_t       _pad;
    uint32_t      data32;     // index for sub-command 8
    uint8_t       bytes[32];  // raw value (float is bytes[0..4], little-endian)
} SMCKeyData;                 // total 80 bytes

#define SMC_FLT_TYPE 0x666C7420u   // "flt " as a big-endian FourCC uint32

static io_connect_t g_smc = 0;
#define MAX_SENSORS 256
static uint32_t g_cpuKeys[MAX_SENSORS]; static int g_cpuCount = 0;
static uint32_t g_gpuKeys[MAX_SENSORS]; static int g_gpuCount = 0;

// ---------------------------------------------------------------------------
// IOHID thermal fallback
// ---------------------------------------------------------------------------
typedef void*    (*HIDCreateFn)(CFAllocatorRef);
typedef int      (*HIDSetMatchFn)(void *, CFDictionaryRef);
typedef CFArrayRef (*HIDCopySvcFn)(void *);
typedef CFStringRef (*HIDSvcPropFn)(void *, CFStringRef);
typedef void*    (*HIDSvcEventFn)(void *, int64_t, int32_t, int64_t);
typedef double   (*HIDEvFloatFn)(void *, int64_t);

static HIDCreateFn   g_hidCreate = NULL;
static HIDSetMatchFn g_hidSetMatch = NULL;
static HIDCopySvcFn  g_hidCopySvc = NULL;
static HIDSvcPropFn  g_hidProp = NULL;
static HIDSvcEventFn g_hidEvent = NULL;
static HIDEvFloatFn  g_hidFloat = NULL;
static void         *g_hidClient = NULL;

// 1 = SMC float keys, 2 = IOHID. Chosen at init.
static int g_tempSource = 0;

// ---------------------------------------------------------------------------

static int smc_read(const SMCKeyData *in, SMCKeyData *out) {
    size_t olen = sizeof(SMCKeyData);
    kern_return_t r = IOConnectCallStructMethod(g_smc, 2, in,
                                                sizeof(SMCKeyData), out, &olen);
    if (r != kIOReturnSuccess) return -1;
    if (out->result == 132) return -2;
    if (out->result != 0)   return -3;
    return 0;
}

static uint32_t smc_key_by_index(uint32_t index) {
    SMCKeyData in;  memset(&in, 0, sizeof(in));
    in.data8 = 8; in.data32 = index;
    SMCKeyData out; memset(&out, 0, sizeof(out));
    if (smc_read(&in, &out) != 0) return 0;
    return out.key;
}

static int smc_key_info(uint32_t key, uint32_t *data_size, uint32_t *data_type) {
    SMCKeyData in;  memset(&in, 0, sizeof(in));
    in.data8 = 9; in.key = key;
    SMCKeyData out; memset(&out, 0, sizeof(out));
    if (smc_read(&in, &out) != 0) return -1;
    *data_size = out.kinfo.data_size;
    *data_type = out.kinfo.data_type;
    return 0;
}

static float smc_read_float(uint32_t key) {
    SMCKeyData in;  memset(&in, 0, sizeof(in));
    in.data8 = 5; in.key = key;
    in.kinfo.data_size = 4;                    // macmon passes the cached key_info
    in.kinfo.data_type = SMC_FLT_TYPE;         // in the read request; do the same
    SMCKeyData out; memset(&out, 0, sizeof(out));
    if (smc_read(&in, &out) != 0) return (0.0f / 0.0f);
    float f; memcpy(&f, &out.bytes[0], 4);    // little-endian on ARM
    return f;
}

static int smc_open(void) {
    io_iterator_t it;
    if (IOServiceGetMatchingServices(kIOMainPortDefault,
                                     IOServiceMatching("AppleSMC"), &it) != kIOReturnSuccess)
        return -1;
    io_service_t svc;
    while ((svc = IOIteratorNext(it)) != 0) {
        char name[256] = {0};
        if (IORegistryEntryGetName(svc, name) == KERN_SUCCESS &&
            strcmp(name, "AppleSMCKeysEndpoint") == 0) {
            if (IOServiceOpen(svc, mach_task_self(), 0, &g_smc) == kIOReturnSuccess) {
                IOObjectRelease(svc); break;
            }
        }
        IOObjectRelease(svc);
    }
    IOObjectRelease(it);
    return g_smc ? 0 : -1;
}

// Total number of keys the SMC exposes ("#KEY"; value is a big-endian u32).
static int smc_key_count(uint32_t *count) {
    const uint32_t hashKey = 0x234B4559u;   // "#KEY" as a big-endian FourCC
    uint32_t ds = 0, dt = 0;
    if (smc_key_info(hashKey, &ds, &dt) != 0) return -1;
    SMCKeyData in;  memset(&in, 0, sizeof(in));
    in.data8 = 5; in.key = hashKey;
    in.kinfo.data_size = ds; in.kinfo.data_type = dt;
    SMCKeyData out; memset(&out, 0, sizeof(out));
    if (smc_read(&in, &out) != 0) return -1;
    uint32_t n; memcpy(&n, &out.bytes[0], 4);
    *count = __builtin_bswap32(n);
    return 0;
}

// Enumerate SMC temperature keys exactly like macmon: walk every key index
// (unreadable indices are skipped, not fatal), keep 4-byte "flt " keys named
// Tp*/Te*/Ts* (CPU) or Tg* (GPU) whose value can actually be read. Key names
// come back as big-endian FourCCs, so byte-swap before prefix matching.
static void smc_enumerate_temps(void) {
    g_cpuCount = g_gpuCount = 0;
    uint32_t count = 0;
    if (smc_key_count(&count) != 0 || count == 0 || count > 65536) return;
    for (uint32_t i = 0; i < count; i++) {
        uint32_t key = smc_key_by_index(i);
        if (key == 0) continue;
        uint32_t sw = __builtin_bswap32(key);
        char b[5]; memcpy(b, &sw, 4); b[4] = '\0';
        int isCpu = (b[0] == 'T' && (b[1] == 'p' || b[1] == 'e' || b[1] == 's'));
        int isGpu = (b[0] == 'T' && b[1] == 'g');
        if (!isCpu && !isGpu) continue;
        uint32_t ds = 0, dt = 0;
        if (smc_key_info(key, &ds, &dt) != 0) continue;
        if (dt != SMC_FLT_TYPE || ds != 4) continue;
        float v = smc_read_float(key);          // macmon: keep only readable keys
        if (v != v) continue;                   // NaN == read failed
        if (isCpu && g_cpuCount < MAX_SENSORS) g_cpuKeys[g_cpuCount++] = key;
        else if (isGpu && g_gpuCount < MAX_SENSORS) g_gpuKeys[g_gpuCount++] = key;
    }
}

static double smc_avg_temp(const uint32_t *keys, int n) {
    if (n == 0) return 0.0;
    double sum = 0; int got = 0;
    for (int i = 0; i < n; i++) {
        float v = smc_read_float(keys[i]);
        if (v > 0.0f && v <= 150.0f) { sum += v; got++; }
    }
    return got ? sum / (double)got : 0.0;
}

// ---------------------------------------------------------------------------
// IOHID thermal
// ---------------------------------------------------------------------------

static int iohid_open(void) {
    g_hidCreate   = (HIDCreateFn)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreate");
    g_hidSetMatch = (HIDSetMatchFn)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientSetMatching");
    g_hidCopySvc  = (HIDCopySvcFn)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCopyServices");
    g_hidProp     = (HIDSvcPropFn)dlsym(RTLD_DEFAULT, "IOHIDServiceClientCopyProperty");
    g_hidEvent    = (HIDSvcEventFn)dlsym(RTLD_DEFAULT, "IOHIDServiceClientCopyEvent");
    g_hidFloat    = (HIDEvFloatFn)dlsym(RTLD_DEFAULT, "IOHIDEventGetFloatValue");
    if (!g_hidCreate || !g_hidSetMatch || !g_hidCopySvc || !g_hidProp ||
        !g_hidEvent || !g_hidFloat) return -1;

    int page = 0xff00, usage = 0x5;
    CFNumberRef np = CFNumberCreate(NULL, kCFNumberSInt32Type, &page);
    CFNumberRef nu = CFNumberCreate(NULL, kCFNumberSInt32Type, &usage);
    const void *kk[2] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
    const void *vv[2] = { np, nu };
    CFDictionaryRef match = CFDictionaryCreate(NULL, kk, vv, 2,
                                &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(np); CFRelease(nu);

    g_hidClient = g_hidCreate(kCFAllocatorDefault);
    if (!g_hidClient) { CFRelease(match); return -1; }
    g_hidSetMatch(g_hidClient, match);
    CFRelease(match);
    return 0;
}

// Returns averaged CPU and GPU package temps from IOHID thermal sensors.
static void iohid_temps(double *cpu_out, double *gpu_out) {
    *cpu_out = 0.0; *gpu_out = 0.0;
    if (!g_hidClient) return;
    CFArrayRef svcs = g_hidCopySvc(g_hidClient);
    if (!svcs) return;
    double cpu_sum = 0, gpu_sum = 0; int cpu_n = 0, gpu_n = 0;
    for (CFIndex i = 0; i < CFArrayGetCount(svcs); i++) {
        void *sc = (void *)CFArrayGetValueAtIndex(svcs, i);
        CFStringRef nm = g_hidProp(sc, CFSTR("Product"));
        if (!nm) continue;
        char buf[128]; if (!CFStringGetCString(nm, buf, sizeof(buf), kCFStringEncodingUTF8)) continue;
        void *ev = g_hidEvent(sc, 15 /*kIOHIDEventTypeTemperature*/, 0, 0);
        if (!ev) continue;
        double t = g_hidFloat(ev, 15LL << 16);
        if (t <= 0.0 || t > 150.0) continue;
        if (strstr(buf, "tcal") != NULL) continue;   // calibration constant, not a live temp
        // GPU die lives on the PMU2 power domain; SoC/CPU on PMU. Also accept
        // the Intel/M1 "GPU MTR"/"pACC"/"eACC" sensor naming as a fallback.
        int is_gpu = (strstr(buf, "PMU2") != NULL) || (strstr(buf, "GPU") != NULL) ||
                     (strstr(buf, "gfx") != NULL);
        int is_cpu = (!is_gpu && strstr(buf, "PMU") != NULL) ||
                     (strstr(buf, "ACC") != NULL) || (strstr(buf, "CPU") != NULL) ||
                     (strstr(buf, "SoC") != NULL);
        if (!is_gpu && !is_cpu) continue;
        if (is_gpu) { gpu_sum += t; gpu_n++; }
        else        { cpu_sum += t; cpu_n++; }
    }
    CFRelease(svcs);
    if (cpu_n) *cpu_out = cpu_sum / cpu_n;
    if (gpu_n) *gpu_out = gpu_sum / gpu_n;
}

// ---------------------------------------------------------------------------
// IOReport GPU
// ---------------------------------------------------------------------------

static int ioreport_gpu_init(void) {
    g_ioreport = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY);
    if (!g_ioreport) return -1;

    g_copyChannels = (CopyChannelsFn)dlsym(g_ioreport, "IOReportCopyChannelsInGroup");
    g_createSub    = (CreateSubscriptionFn)dlsym(g_ioreport, "IOReportCreateSubscription");
    g_createSamples= (CreateSamplesFn)dlsym(g_ioreport, "IOReportCreateSamples");
    g_samplesDelta = (CreateSamplesDeltaFn)dlsym(g_ioreport, "IOReportCreateSamplesDelta");
    g_stateCount   = (StateGetCountFn)dlsym(g_ioreport, "IOReportStateGetCount");
    g_stateName    = (StateGetNameFn)dlsym(g_ioreport, "IOReportStateGetNameForIndex");
    g_stateRes     = (StateGetResidencyFn)dlsym(g_ioreport, "IOReportStateGetResidency");
    g_chanName     = (ChannelGetNameFn)dlsym(g_ioreport, "IOReportChannelGetChannelName");
    if (!g_copyChannels || !g_createSub || !g_createSamples || !g_samplesDelta ||
        !g_stateCount || !g_stateName || !g_stateRes || !g_chanName) {
        dlclose(g_ioreport); g_ioreport = NULL; return -1;
    }

    // 5-arg signature: group, subgroup, reserved a, b, c.
    CFDictionaryRef ch = g_copyChannels(CFSTR("GPU Stats"),
                                        CFSTR("GPU Performance States"), 0, 0, 0);
    if (!ch) return -1;
    g_chan = CFDictionaryCreateMutableCopy(NULL, 0, ch);
    CFRelease(ch);

    // 5-arg: (NULL, desired, &subbed, channelID=0, NULL).
    g_subs = g_createSub(NULL, g_chan, &g_subbed, 0, NULL);
    if (!g_subs) { CFRelease(g_chan); g_chan = NULL; return -1; }
    return 0;
}

// Read GPU DVFS table (raw values) from IORegistry pmgr/voltage-states9.
static void read_gpu_freqs(void) {
    io_iterator_t it;
    if (IOServiceGetMatchingServices(kIOMainPortDefault,
                                     IOServiceMatching("AppleARMIODevice"), &it) != kIOReturnSuccess)
        return;
    io_service_t svc;
    while ((svc = IOIteratorNext(it)) != 0) {
        char name[256] = {0};
        if (IORegistryEntryGetName(svc, name) == KERN_SUCCESS &&
            strstr(name, "pmgr") != NULL) {   // "pmgr" or "pmgr-child"
            CFDataRef data = IORegistryEntryCreateCFProperty(
                svc, CFSTR("voltage-states9"), kCFAllocatorDefault, 0);
            if (data) {
                CFIndex len = CFDataGetLength(data);
                const uint8_t *p = CFDataGetBytePtr(data);
                int n = (int)(len / 8);
                if (n > 0) {
                    g_gpuFreqs = (uint32_t *)malloc(sizeof(uint32_t) * n);
                    for (int i = 0; i < n; i++) {
                        uint32_t freq; memcpy(&freq, p + i * 8, 4);  // freq is LE u32
                        g_gpuFreqs[i] = freq;
                    }
                    g_gpuFreqCount = n;
                }
                CFRelease(data);
            }
        }
        IOObjectRelease(svc);
        if (g_gpuFreqCount > 0) break;
    }
    IOObjectRelease(it);
}

// Compute scaled/active ratio from a GPUPH channel item's residency states.
// Mirrors macmon's calc_freq_from_residencies exactly: `usage` covers exactly
// `freqs.len()` states after the offset (trailing extra states such as the
// P14/P15 above the DVFS table are excluded), `total` covers all states.
static double gpu_ratio_from_item(CFDictionaryRef item) {
    CFIndex count = g_stateCount(item);
    if (count <= 0) return 0.0;

    char   **names = (char **)malloc(sizeof(char *) * count);
    int64_t *res   = (int64_t *)malloc(sizeof(int64_t) * count);
    double   total = 0.0;
    for (CFIndex i = 0; i < count; i++) {
        names[i] = (char *)malloc(32);
        CFStringRef nm = g_stateName(item, i);
        if (!nm || !CFStringGetCString(nm, names[i], 32, kCFStringEncodingUTF8))
            names[i][0] = '\0';
        res[i] = g_stateRes(item, i);
        total += (double)res[i];
    }

    CFIndex offset = -1;
    for (CFIndex i = 0; i < count; i++) {
        if (strcmp(names[i], "IDLE") && strcmp(names[i], "DOWN") && strcmp(names[i], "OFF")) {
            offset = i; break;
        }
    }
    if (offset < 0) { for (CFIndex i=0;i<count;i++) free(names[i]); free(names); free(res); return 0.0; }

    int nf = g_gpuFreqCount;
    const uint32_t *freqs = (nf > 1) ? &g_gpuFreqs[1] : g_gpuFreqs;  // skip OFF entry
    int fn = (nf > 1) ? (nf - 1) : nf;

    if (fn > 0) {
        double usage = 0.0;
        for (CFIndex i = offset; i < offset + fn && i < count; i++) usage += (double)res[i];

        double avg = 0.0;
        for (int i = 0; i < fn && offset + i < count; i++) {
            double p = usage > 0 ? (double)res[offset + i] / usage : 0;
            avg += p * (double)freqs[i];
        }
        double active = usage / total;
        double minf = (double)freqs[0];
        double maxf = (double)freqs[fn - 1];
        double scaled = (avg > minf ? avg : minf) * active / maxf;
        for (CFIndex i = 0; i < count; i++) free(names[i]);
        free(names); free(res);
        return scaled > 0 ? scaled : 0.0;
    }

    // No DVFS table: fall back to plain active residency of non-IDLE states.
    double usage = 0.0;
    for (CFIndex i = offset; i < count; i++) usage += (double)res[i];
    double active = (total > 0) ? usage / total : 0.0;
    for (CFIndex i = 0; i < count; i++) free(names[i]);
    free(names); free(res);
    return active > 0 ? active : 0.0;
}

// Walk the delta's "IOReportChannels" array, find GPUPH, compute ratio.
static double gpu_ratio_from_delta(CFTypeRef delta) {
    double result = 0.0;
    CFArrayRef arr = (CFArrayRef)CFDictionaryGetValue((CFDictionaryRef)delta,
                                                      CFSTR("IOReportChannels"));
    if (!arr || CFGetTypeID(arr) != CFArrayGetTypeID()) return 0.0;
    CFIndex n = CFArrayGetCount(arr);
    for (CFIndex i = 0; i < n; i++) {
        CFDictionaryRef item = (CFDictionaryRef)CFArrayGetValueAtIndex(arr, i);
        if (CFGetTypeID(item) != CFDictionaryGetTypeID()) continue;
        CFStringRef cn = g_chanName(item);
        char buf[64];
        if (cn && CFStringGetCString(cn, buf, sizeof(buf), kCFStringEncodingUTF8) &&
            strcmp(buf, "GPUPH") == 0) {
            result = gpu_ratio_from_item(item);
            break;
        }
    }
    return result;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

int corebar_sensors_init(void) {
    int ok = 0;

    // Temperature: prefer SMC float keys, fall back to IOHID thermal.
    if (smc_open() == 0) {
        smc_enumerate_temps();
        if (g_cpuCount + g_gpuCount > 0) { g_tempSource = 1; ok = 1; }
    }
    if (g_tempSource == 0 && iohid_open() == 0) { g_tempSource = 2; ok = 1; }

    // GPU load via IOReport.
    if (ioreport_gpu_init() == 0) { read_gpu_freqs(); ok = 1; }

    return ok ? 0 : -1;
}

void corebar_sensors_close(void) {
    if (g_samplePrev) { CFRelease(g_samplePrev); g_samplePrev = NULL; }
    if (g_subs)  { CFRelease(g_subs);  g_subs = NULL; }
    if (g_subbed){ CFRelease(g_subbed);g_subbed = NULL; }
    if (g_chan)  { CFRelease(g_chan);  g_chan = NULL; }
    if (g_gpuFreqs) { free(g_gpuFreqs); g_gpuFreqs = NULL; g_gpuFreqCount = 0; }
    if (g_hidClient) { /* no public teardown needed for our use */ g_hidClient = NULL; }
    if (g_smc)  { IOServiceClose(g_smc); g_smc = 0; }
    if (g_ioreport) { dlclose(g_ioreport); g_ioreport = NULL; }
}

double corebar_gpu_scaled_ratio(void) {
    if (!g_subs || !g_subbed) return 0.0;
    CFTypeRef s = g_createSamples(g_subs, g_subbed, NULL);
    if (!s) return 0.0;
    if (!g_samplePrev) { g_samplePrev = s; return 0.0; }   // prime; no delta yet
    CFTypeRef delta = g_samplesDelta(g_samplePrev, s, NULL);
    CFRelease(g_samplePrev);
    g_samplePrev = s;                                       // window = caller interval
    if (!delta) return 0.0;
    double r = gpu_ratio_from_delta(delta);
    CFRelease(delta);
    return r;
}

double corebar_cpu_temp_c(void) {
    if (g_tempSource == 1) return smc_avg_temp(g_cpuKeys, g_cpuCount);
    double cpu = 0, gpu = 0; iohid_temps(&cpu, &gpu); return cpu;
}

double corebar_gpu_temp_c(void) {
    if (g_tempSource == 1) return smc_avg_temp(g_gpuKeys, g_gpuCount);
    double cpu = 0, gpu = 0; iohid_temps(&cpu, &gpu); return gpu;
}

// ---------------------------------------------------------------------------
// Standalone test:
//   cc -O2 -framework IOKit -framework CoreFoundation -o stest sensors.c -DSTANDALONE_TEST
// ---------------------------------------------------------------------------
#ifdef STANDALONE_TEST
#include <stdio.h>
int main(void) {
    int r = corebar_sensors_init();
    fprintf(stderr, "init=%d  tempSource=%d  smc=%d  subs=%p  subbed=%p  freqs=%d  "
                    "cpuKeys=%d  gpuKeys=%d  sizeofKeyData=%zu\n",
            r, g_tempSource, (int)g_smc, (void*)g_subs, (void*)g_subbed,
            g_gpuFreqCount, g_cpuCount, g_gpuCount, sizeof(SMCKeyData));

    printf("cpu_temp_avg = %.2f C\n", corebar_cpu_temp_c());
    printf("gpu_temp_avg = %.2f C\n", corebar_gpu_temp_c());

    // GPU ratio needs two samples (window = 1s here).
    corebar_gpu_scaled_ratio();
    sleep(1);
    printf("gpu_scaled_ratio = %.4f\n", corebar_gpu_scaled_ratio());

    corebar_sensors_close();
    return 0;
}
#endif
