#ifndef NV2A_PB_TRACE_H
#define NV2A_PB_TRACE_H

#include <stdint.h>

/* Runtime-only checkpoints for a stuck software-method/PGRAPH handoff.
 * Enabled with RECOMP_PGRAPH_TRACE=1; summaries are emitted only while a
 * hooked NOP trap has remained pending for two seconds. */
typedef enum Nv2aPbTraceStage {
    NV2A_PB_TRACE_NOP_PUBLISHED,
    NV2A_PB_TRACE_IRQ_ASSERTED,
    NV2A_PB_TRACE_D3D_HANDLER_ENTRY,
    NV2A_PB_TRACE_D3D_ISR_ENTRY,
    NV2A_PB_TRACE_GIL_SUSPEND_BEGIN,
    NV2A_PB_TRACE_GIL_SUSPENDED,
    NV2A_PB_TRACE_IRQL_RAISE_BEGIN,
    NV2A_PB_TRACE_IRQL_RAISE_RETURN,
    NV2A_PB_TRACE_GIL_RESUME_BEGIN,
    NV2A_PB_TRACE_GIL_RESUMED,
    NV2A_PB_TRACE_IRQL_ALREADY_RAISED,
    NV2A_PB_TRACE_TRAP_LOCK_BEGIN,
    NV2A_PB_TRACE_TRAP_LOCK_ACQUIRED,
    NV2A_PB_TRACE_NSOURCE_SET,
    NV2A_PB_TRACE_NSOURCE_CLEAR,
    NV2A_PB_TRACE_GENERATED_HANDLER_RETURN,
    NV2A_PB_TRACE_TRAP_TAKEN_BEGIN,
    NV2A_PB_TRACE_TRAP_TAKEN_SIGNALLED,
    NV2A_PB_TRACE_TRAP_TAKEN_RETURN,
    NV2A_PB_TRACE_TRAP_UNLOCKED,
    NV2A_PB_TRACE_IRQL_RESTORE_BEGIN,
    NV2A_PB_TRACE_IRQL_RESTORED,
    NV2A_PB_TRACE_ACK_WAIT_DONE,
    NV2A_PB_TRACE_ACK_RETURN,
    NV2A_PB_TRACE_STAGE_COUNT
} Nv2aPbTraceStage;

void nv2a_pb_trace_begin(void);
void nv2a_pb_trace_end(void);
void nv2a_pb_trace_stage(Nv2aPbTraceStage stage);
void nv2a_pb_trace_report(uint32_t nop_param);

#endif
