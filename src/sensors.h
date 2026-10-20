// sensors.h — native hardware sampling for MacMonBar
//
// Replaces the `macmon pipe` child process. On Apple Silicon the GPU load
// ("GPU Stats" / "GPU Performance States") lives behind libIOReport, and
// temperature behind AppleSMC — both are plain C APIs, so there is no reason
// to spawn a subprocess and parse JSON for it. Kept in C (not Swift) so the
// hot path has zero ARC/bridging overhead and the whole thing is easy to read.
//
// Thread model: init() once; the getters are called from the app's sampler
// timer (main thread). g_channels/g_smc are read-only after init, so no lock.
#ifndef MACMONBAR_SENSORS_H
#define MACMONBAR_SENSORS_H

#ifdef __cplusplus
extern "C" {
#endif

// Returns 0 on success. Non-zero if neither GPU nor SMC could be opened.
int  macmonbar_sensors_init(void);
void macmonbar_sensors_close(void);

// GPU "scaled ratio" in 0..1 — same quantity macmon reports as gpu_scaled_ratio.
double macmonbar_gpu_scaled_ratio(void);

// CPU package temperature in °C (average of Tp*/Te*/Ts* sensors),
// and GPU temperature in °C (Tg* sensors). 0.0 if unavailable.
double macmonbar_cpu_temp_c(void);
double macmonbar_gpu_temp_c(void);

#ifdef __cplusplus
}
#endif
#endif // MACMONBAR_SENSORS_H
