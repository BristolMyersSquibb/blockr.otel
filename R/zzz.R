.onLoad <- function(libname, pkgname) {
  # nocov start
  blockr.core::register_blocks(
    "new_app_driver_block",
    name = "App Driver",
    description = "Start a Shiny app via shinytest2 AppDriver with OTEL instrumentation",
    category = "input",
    icon = "play-circle",
    package = utils::packageName(),
    overwrite = TRUE
  )
  blockr.core::register_blocks(
    "new_otel_block",
    name = "OTel Profiler",
    description = "Collect spans from connected app drivers via otel-desktop-viewer",
    category = "transform",
    icon = "activity",
    package = utils::packageName(),
    overwrite = TRUE
  )
  # nocov end
}
