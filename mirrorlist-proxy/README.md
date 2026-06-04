# mirrorlist-proxy-experiment

Little experiment to reuse our infra for cached Archlinux mirrorlist

## Building and Running with Docker

You can also build and run the web dashboard using Docker.

### Build the Docker Image

To build the Docker image, run the following command from the root directory:

```bash
docker build -t archmirrorlist-proxy .
```

### Run the Docker Container

To run the Docker container, use the following command:

```bash
docker run -p 8080:8080 archmirrorlist-proxy
```

The application will be available at [http://localhost:8080](http://localhost:8080).

### Configuration

The following environment variables can be used to configure the application:

| Variable         | Description                               | Default   |
| ---------------- | ----------------------------------------- | --------- |
| `PORT`           | The port the application will listen on.  | `8080`    |
| `REFRESH_INTERVAL` | The interval at which the mirrorlist is refreshed. | `5m`      |
| `REQUEST_TIMEOUT`  | The timeout for requests to the Arch Linux mirrorlist service. | `30m`     |
