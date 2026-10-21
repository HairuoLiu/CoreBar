// sensors.h — native hardware sampling for CoreBar
//
// Thread model: init() once; the getters are called from the app's sampler
// timer (main thread). g_channels/g_smc are read-only after init, so no lock.
#ifndef COREBAR_SENSORS_H
#define COREBAR_SENSORS_H

#ifdef __cplusplus
extern "C" {
#endif

// Returns 0 on success. Non-zero if hardware monitoring could not be opened.
int  corebar_sensors_init(void);
void corebar_sensors_close(void);

// GPU "scaled ratio" in 0..1 — highest/active GPU utilization
double corebar_gpu_scaled_ratio(void);

// Detailed dual-GPU metrics (returns -1.0 if not present)
double corebar_dgpu_ratio(void); // Discrete GPU (AMD/NVIDIA)
double corebar_igpu_ratio(void); // Integrated GPU (Intel)
int    corebar_has_dual_gpu(void); // 1 if both discrete and integrated GPUs exist

// CPU package temperature in °C and GPU temperature in °C
double corebar_cpu_temp_c(void);
double corebar_gpu_temp_c(void);

#ifdef __cplusplus
}
#endif
#endif // COREBAR_SENSORS_H
