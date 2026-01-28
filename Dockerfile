# Stage 1: Build the application
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /app

# Copy project files
COPY pom.xml .
COPY src ./src
COPY style ./style

# Build with Maven (skip tests to save time)
RUN mvn clean package -Dmaven.test.skip=true

# Stage 2: Create the runtime image
FROM eclipse-temurin:21-jre
MAINTAINER breeze
WORKDIR /app

# Copy the compiled jar from the build stage
COPY --from=build /app/target/rocketmq-exporter-0.0.3-SNAPSHOT-exec.jar rocketmq-exporter.jar

EXPOSE 5557
ENTRYPOINT ["java","-jar","rocketmq-exporter.jar"]
