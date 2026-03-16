# blockr.otel

This is a test repo to use OpenTelemetry with blockr apps and analyse results with ... blockr!

## OTEL setup via otel desktop viewer

1. Setup OTEL in app (.Renviron settings)

```
#.Renviron
OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:4318"
OTEL_TRACES_EXPORTER="otlp"
OTEL_EXPORTER_OTLP_PROTOCOL="http/protobuf"
OTEL_SERVICE_NAME="my-app"
```

1. Start otel desktop viewer cli tool (see )
Requires go  to be installed...

```
$(go env GOPATH)/bin/otel-desktop-viewer
````

Viewer live at <http://localhost:8000/traces> (or any other port if this was configured)

1. Start app and look for spans appear.
2. Extract spans with httr2 (the viewer does not provide aggregated results, timelines, ... only span by span detailed view)
3. Analyse data with blockr workflow.
4. Look for outstanding spans/discuss.

## TBD

- Better orchestration (ex: headless startup profiling):
  - A block that starts up `otel-desktop-viewer` (also checks whether `go` is installed) + the app to test via shinytest2 headless driver (see specs at <https://rstudio.github.io/shinytest2/reference/AppDriver.html>). For each app we need to set a unique `OTEL_SERVICE_NAME` to recognize it from the collector data. For the app location, we need `blockr.io`, the `new_read_block` and we provide the path of the app file. We can add or remove path as much as we want.

```r
app1 <- withr::with_envvar(
  c(OTEL_SERVICE_NAME = "app1"),
  AppDriver$new("path/to/app1")
)

app2 <- withr::with_envvar(
  c(OTEL_SERVICE_NAME = "app2"),
  AppDriver$new("path/to/app2")
)
```

    - The CLI flags are: otel-desktop-viewer --browser 9000 --http 5318 --grpc 5317
    - `browser` <port> — Web UI / JSON-RPC port (default 8000)
    - `http` <port> — OTLP HTTP receiver (default 4318)
    - `grpc` <port> — OTLP gRPC receiver (default 4317)

- Then this same block can play with the app with shinytest2 (via the AppDriver) to trigger more spans and stop shinytest2, then close the connection otel-desktop-viewer.
- A block that creates the interactive timeline chart: echarts (<https://echarts.apache.org/examples/en/editor.html?c=flame-graph>), flame graph, gantt? Capabilities to display to filter spans before.
