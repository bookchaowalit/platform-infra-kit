# Official Docker Hub manifests resolved 2026-10-15; accepted platform is linux/amd64.
FROM --platform=linux/amd64 postgres:16-bookworm@sha256:ec9f656f17c8b4dfebf49e58cf5c46d493d4846d4ea6d8b85d0637f68ee33bfc AS pgtools
FROM --platform=linux/amd64 python:3.12-slim-bookworm@sha256:2ed6491b93cd49272ee6de2b5a38440c3448360322c089fc23e370722d74179d AS builder
ARG INFRA_SOURCE_SHA
ENV PIP_CONFIG_FILE=/dev/null PIP_INDEX_URL=https://pypi.org/simple PIP_EXTRA_INDEX_URL=""
WORKDIR /build
COPY shared_infra/railway_build.py /build/railway_build.py
COPY shared-infra/railway/sources.json /build/sources.json
RUN python railway_build.py --config sources.json --infra-sha "$INFRA_SOURCE_SHA" --output /release/wheels
FROM --platform=linux/amd64 python:3.12-slim-bookworm@sha256:2ed6491b93cd49272ee6de2b5a38440c3448360322c089fc23e370722d74179d
COPY --from=pgtools /usr/lib/postgresql/16/bin/pg_dump /usr/lib/postgresql/16/bin/pg_dump
COPY --from=pgtools /usr/lib/postgresql/16/bin/pg_restore /usr/lib/postgresql/16/bin/pg_restore
# Both images use Debian bookworm. Include the client's exact shared libraries;
# no apt repository or mutable OS package resolution runs in the runtime build.
COPY --from=pgtools /usr/lib/x86_64-linux-gnu /usr/lib/x86_64-linux-gnu
COPY --from=builder /release /release
RUN python -c 'import hashlib,json,pathlib; p=pathlib.Path("/release"); expected=json.loads((p/"wheel-manifest.json").read_text())["wheels"]; files=list((p/"wheels").iterdir()); assert all(f.is_file() and not f.is_symlink() and f.suffix==".whl" for f in files); assert {f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in files}==expected' \
 && python -m pip install --no-index --only-binary=:all: --no-deps /release/wheels/*.whl \
 && python -m pip check \
 && python -c 'import platform_backend_core,platform_workflow,platform_data,platform_developer,platform_security,platform_communication,platform_media,platform_payment,platform_observability,shared_infra.railway_staging' \
 && /usr/lib/postgresql/16/bin/pg_dump --version \
 && /usr/lib/postgresql/16/bin/pg_restore --version \
 && rm -rf /release/wheels
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
USER 65532:65532
CMD ["python", "-m", "shared_infra.railway_staging", "serve"]
