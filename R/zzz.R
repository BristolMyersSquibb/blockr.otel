.onLoad <- function(libname, pkgname) {
  # nocov start
  blockr.core::register_blocks(
    "new_otel_block",
    name = "OTel Profiler",
    description = "Start otel-desktop-viewer, launch Shiny apps, collect spans",
    category = "input",
    icon = "activity",
    package = utils::packageName(),
    overwrite = TRUE
  )
  # nocov end
}
