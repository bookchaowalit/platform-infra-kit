# Pass a reviewed python:3.12-slim image pinned by @sha256, never a mutable tag.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /app
COPY wheels/ /wheels/
COPY wheel-manifest.json /wheel-manifest.json
RUN python -c 'import hashlib,json,pathlib; p=pathlib.Path("/wheels"); m=json.load(open("/wheel-manifest.json")); files=list(p.iterdir()); assert p.is_dir() and not p.is_symlink() and files and all(f.is_file() and not f.is_symlink() and f.suffix==".whl" for f in files); a={f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in files}; assert m["version"]==1 and a==m["wheels"]' \
    && python -m pip install --no-index --only-binary=:all: --find-links=/wheels \
       platform-infra-kit==0.1.0 platform-data==0.1.0 platform-workflow==0.1.0 \
       platform-developer==0.1.0 platform-security==0.1.0 platform-communication==0.1.0 \
       platform-media==0.1.0 platform-payment==0.1.0 \
    && python -m pip check
USER 10001:10001
EXPOSE 8080
CMD ["python", "-m", "shared_infra.runtime", "serve"]
