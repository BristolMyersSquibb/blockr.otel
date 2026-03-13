# blockr.otel

## OTEL setup via otel desktop viewer

1. Setup OTEL in app (.Renviron settings)

```
#.Renviron
OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:4318"
OTEL_TRACES_EXPORTER="otlp"
OTEL_EXPORTER_OTLP_PROTOCOL="http/protobuf"
```

1. Start otel desktop viewer cli tool (see )
Requires go  to be installed...

```
$(go env GOPATH)/bin/otel-desktop-viewer
````

Viewer live at <http://localhost:8000/traces> (or any other port if this was configured)

1. Start app and play until spans appear
2. Extract spans with httr2 (the viewer does not provide aggregated results, timelines, ... only span by span detailed view)
3. Analyse data with blockr workflow.
4. Look for outstanding spans/discuss.

## TBD

- Interactive timeline chart.
- Display more spans (or add filter before timeline block).
- Make a block recorder, block extractor and block reader.
