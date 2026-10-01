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
FC_EXPORT void fc_rdp_secure_attention(void *view);
FC_EXPORT int fc_rdp_status(void *view);
FC_EXPORT int fc_rdp_has_frame(void *view);
FC_EXPORT uint32_t fc_rdp_error(void *view);
FC_EXPORT int fc_rdp_failure(void *view);
// Stable FreeRDP connection-state token for safe diagnostics, or NULL if unset.
FC_EXPORT const char *fc_rdp_connection_phase(void *view);
// RDP security protocols observed during negotiation (MS-RDPBCGR bit flags).
FC_EXPORT uint32_t fc_rdp_requested_protocols(void *view);
FC_EXPORT uint32_t fc_rdp_selected_protocol(void *view);
// Bit 0: command-line settings parsed; bit 1: username supplied; bit 2: password supplied.
// Credential contents are never returned.
FC_EXPORT uint32_t fc_rdp_input_state(void *view);
// The graphics codec negotiated by this RDP connection, or an empty string
// before negotiation. The returned string is owned by the runtime.
FC_EXPORT const char *fc_rdp_codec(void *view);
// FreeRDP's measured RDP network round-trip time, or zero before a sample exists.
FC_EXPORT uint32_t fc_rdp_round_trip_milliseconds(void *view);
