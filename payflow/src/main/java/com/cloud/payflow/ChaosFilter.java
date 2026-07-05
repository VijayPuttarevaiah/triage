package com.cloud.payflow;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;

/**
 * Applies active chaos flags to BUSINESS endpoints only (/transactions/**).
 *
 * Design decision (defend this in the TA meeting):
 * /health is deliberately EXCLUDED from the error storm, so the ALB keeps the
 * task in service while it returns 5xx to users. This keeps the three chaos
 * scenarios cleanly separated at the alarm level:
 *   - Scenario 1 (error storm)  -> 5xx-rate alarm fires, host stays "healthy"
 *   - Scenario 2 (latency)      -> p99 latency alarm fires
 *   - Scenario 3 (crash)        -> UnhealthyHostCount alarm fires
 * If /health also failed during a storm, scenarios 1 and 3 would conflate and
 * the diagnosis step would have nothing interesting to distinguish.
 */
@Component
public class ChaosFilter extends OncePerRequestFilter {

    private static final Logger log = LoggerFactory.getLogger(ChaosFilter.class);

    @Override
    protected void doFilterInternal(HttpServletRequest request,
                                    HttpServletResponse response,
                                    FilterChain filterChain) throws ServletException, IOException {

        String path = request.getRequestURI();
        boolean businessEndpoint = path.startsWith("/transactions");

        if (businessEndpoint && ChaosState.LATENCY_INJECTION.get()) {
            try {
                Thread.sleep(3000);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }

        if (businessEndpoint && ChaosState.ERROR_STORM.get()) {
            // Structured log line: the evidence Lambda's Logs Insights query
            // will surface these, giving the LLM a real signal to diagnose.
            log.error("CHAOS_ERROR_STORM active - failing request path={} method={}",
                    path, request.getMethod());
            response.setStatus(500);
            response.setContentType("application/json");
            response.getWriter().write(
                    "{\"error\":\"internal_error\",\"detail\":\"transaction processor unavailable\"}");
            return;
        }

        filterChain.doFilter(request, response);
    }
}
