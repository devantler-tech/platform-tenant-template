# Placeholder Dockerfile — replace with your application's build.
#
# It is deliberately self-consistent with the deploy/ scaffold so a freshly
# created tenant deploys cleanly before you swap in your real app: it runs as a
# non-root user and serves HTTP on port 3000, matching deploy/deployment.yaml's
# securityContext (runAsNonRoot, readOnlyRootFilesystem) and its liveness/readiness
# probes. Replace it with your stack's (typically multi-stage) build.
FROM python:3.15.0rc1-alpine
WORKDIR /app
RUN printf '<!doctype html><title>platform-tenant-template</title><h1>Replace this placeholder with your app.</h1>\n' > index.html
EXPOSE 3000
USER 1000
CMD ["python", "-m", "http.server", "3000"]
