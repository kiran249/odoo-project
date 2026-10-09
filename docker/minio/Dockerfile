# MinIO built from source. MinIO no longer publishes community container
# images, so the pipeline builds this pinned release and pushes it to ECR.
ARG MINIO_RELEASE=RELEASE.2025-10-15T17-29-55Z
ARG GO_IMAGE=golang:1.24-bookworm

FROM ${GO_IMAGE} AS build
ARG MINIO_RELEASE
RUN git clone --depth 1 --branch "${MINIO_RELEASE}" https://github.com/minio/minio.git /src
WORKDIR /src
RUN CGO_ENABLED=0 go build -trimpath -tags kqueue \
      -ldflags "$(go run buildscripts/gen-ldflags.go)" -o /out/minio

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/minio /usr/bin/minio
EXPOSE 9000 9001
ENTRYPOINT ["/usr/bin/minio"]
