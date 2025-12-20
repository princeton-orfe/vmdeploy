# Dockerfile for running vmdeploy security tests
# Usage: docker build -t vmdeploy-tests ./tests && docker run vmdeploy-tests

FROM alpine:3.19

RUN apk add --no-cache bash grep coreutils

WORKDIR /app

COPY main.bicep main.json deploy.sh transfer.sh configure-security-contacts.sh ./
COPY tests/test-security.sh ./tests/

RUN chmod +x tests/test-security.sh configure-security-contacts.sh

CMD ["./tests/test-security.sh"]
