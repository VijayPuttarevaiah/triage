# ── Stage 1: build ──────────────────────────────────────────────────────────
FROM maven:3.9-eclipse-temurin-17 AS build
WORKDIR /app
# Cache dependencies separately from source for faster rebuilds
COPY pom.xml .
RUN mvn -q dependency:go-offline
COPY src ./src
RUN mvn -q package -DskipTests

# ── Stage 2: runtime ────────────────────────────────────────────────────────
FROM eclipse-temurin:17-jre
WORKDIR /app
COPY --from=build /app/target/payflow-1.0.0.jar app.jar
EXPOSE 8080
# Container-aware JVM sizing for a 0.5GB Fargate task
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75.0", "-jar", "app.jar"]
