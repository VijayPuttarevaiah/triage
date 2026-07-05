package com.cloud.payflow;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

/**
 * Fault injection surface + health check.
 *
 * SECURITY NOTE for the report: in this demo the chaos endpoints are open
 * because the ALB is the only entry point and the project is short-lived.
 * Production design: these would sit behind auth (or not exist at all -
 * chaos would be injected via a separate tool like AWS FIS), and you should
 * say so in the Security pillar trade-offs.
 */
@RestController
public class ChaosController {

    private static final Logger log = LoggerFactory.getLogger(ChaosController.class);

    /** ALB health check target. Deliberately unaffected by the error storm (see ChaosFilter). */
    @GetMapping("/health")
    public ResponseEntity<Map<String, String>> health() {
        return ResponseEntity.ok(Map.of("status", "UP"));
    }

    @PostMapping("/chaos/errors")
    public ResponseEntity<Map<String, String>> injectErrors() {
        ChaosState.ERROR_STORM.set(true);
        log.warn("CHAOS: error storm ENABLED");
        return ResponseEntity.ok(Map.of("chaos", "error_storm_enabled"));
    }

    @PostMapping("/chaos/latency")
    public ResponseEntity<Map<String, String>> injectLatency() {
        ChaosState.LATENCY_INJECTION.set(true);
        log.warn("CHAOS: latency injection ENABLED");
        return ResponseEntity.ok(Map.of("chaos", "latency_injection_enabled"));
    }

    @PostMapping("/chaos/crash")
    public ResponseEntity<Map<String, String>> crash() {
        log.error("CHAOS: crash requested - task will exit in 2s");
        // Respond first, then kill the JVM so the caller gets confirmation.
        new Thread(() -> {
            try {
                Thread.sleep(2000);
            } catch (InterruptedException ignored) {
                Thread.currentThread().interrupt();
            }
            System.exit(1);
        }).start();
        return ResponseEntity.status(HttpStatus.ACCEPTED).body(Map.of("chaos", "crash_scheduled"));
    }

    @PostMapping("/chaos/reset")
    public ResponseEntity<Map<String, String>> reset() {
        ChaosState.reset();
        log.info("CHAOS: all flags reset");
        return ResponseEntity.ok(Map.of("chaos", "reset"));
    }
}
