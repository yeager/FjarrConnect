// A small, versioned C ABI lets the Swift app load its architecture-specific runtime.
// All calls are made on the main thread. The view owns the connection worker.
#pragma once
#include <stdint.h>
#define FC_EXPORT __attribute__((visibility("default")))
FC_EXPORT uint32_t fc_rdp_abi(void);
// Returns a retained NSView. Credentials stay in memory, never process arguments.
FC_EXPORT void *fc_rdp_create(const char *arguments, const char *translations);
FC_EXPORT void fc_rdp_start(void *view);
FC_EXPORT void fc_rdp_stop(void *view);
FC_EXPORT void fc_rdp_set_active(void *view, int active);
FC_EXPORT int fc_rdp_status(void *view);
FC_EXPORT uint32_t fc_rdp_error(void *view);
FC_EXPORT int fc_rdp_failure(void *view);
