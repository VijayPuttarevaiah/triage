package com.cloud.payflow;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/**
 * PayFlow - a fintech-style transaction API.
 *
 * This is the WORKLOAD PLANE (data plane) of the Triage project: the service
 * being protected. It intentionally stays simple - the interesting engineering
 * lives in the Python control plane that operates it.
 */
@SpringBootApplication
public class PayflowApplication {

    public static void main(String[] args) {
        SpringApplication.run(PayflowApplication.class, args);
    }
}
