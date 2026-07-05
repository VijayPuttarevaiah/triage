package com.cloud.payflow;

import java.util.concurrent.atomic.AtomicBoolean;

/**
 * In-memory fault flags for chaos injection.
 *
 * Deliberately in-memory (not persisted): when Triage remediates by forcing a
 * new ECS deployment, the replacement task starts with clean flags - so a
 * restart genuinely "cures" an error storm, which keeps the demo honest.
 *
 * Report note (limitations section): real production faults are not reset by
 * restarts this reliably; this is a controlled simulation of restart-curable
 * failure modes (bad in-memory state, wedged connection pools, etc.).
 */
public final class ChaosState {

    /** When true, business endpoints return HTTP 500. */
    public static final AtomicBoolean ERROR_STORM = new AtomicBoolean(false);

    /** When true, business endpoints sleep ~3s before responding. */
    public static final AtomicBoolean LATENCY_INJECTION = new AtomicBoolean(false);

    private ChaosState() {
    }

    public static void reset() {
        ERROR_STORM.set(false);
        LATENCY_INJECTION.set(false);
    }
}
