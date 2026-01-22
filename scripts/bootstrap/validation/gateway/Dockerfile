FROM python:3.12-slim

WORKDIR /app

# Install kubectl
RUN apt-get update && apt-get install -y curl && \
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && \
    chmod +x kubectl && \
    mv kubectl /usr/local/bin/

# Install Python dependencies
RUN pip install requests pytest

# Copy validation script
COPY validate-test-endpoint.py /app/

# Run validation
CMD ["python", "-m", "pytest", "validate-test-endpoint.py", "-v"]