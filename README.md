# Polly Docker Image

This folder contains a portable Docker setup that bundles the Polly web app together with the Presidio analyzer and anonymizer services.

## Build

```sh
docker build -t polly-full:latest polly-docker
```

Optional build arguments:

- `POLLY_GIT_REF` – branch/tag/commit to clone (default: `main`).
- `POLLY_GIT_URL` – repository URL (default: `https://github.com/lawlawrd/polly.git`).

## Run

```sh
docker run --rm -p 8081:8081 polly-full:latest
```

Environment variables you can override at runtime:

- `PORT` – external port for Polly (default: 8081).
- `SESSION_SECRET` – session secret for the Express server.
- `PRESIDIO_ANALYZER_PORT` / `PRESIDIO_ANONYMIZER_PORT` – internal Presidio ports (defaults: 5002 / 5001).
- `PRESIDIO_ANALYZER_URL` / `PRESIDIO_ANONYMIZER_URL` – URLs used by Polly to reach Presidio (defaults target the internal services).

After the container is running, open http://localhost:8081 in your browser.
