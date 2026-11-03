library(move2)
library(sf)
library(ggplot2)

## The parameter "data" is reserved for the data object passed on from the previous App.
## The polygon boundary comes from the USER_FILE setting "polygon" (with a fixed fallback file
## in provided-app-files/polygon/) and is read with getAuxiliaryFilePath("polygon").

# to display messages to the user in the log file of the App in MoveApps
# one can use the function from the src/common/logger.R file:
# logger.fatal(), logger.error(), logger.warn(), logger.info(), logger.debug(), logger.trace()

######### Helpers ##############

### helper 1: read polygon boundary file (.zip shapefile or .gpkg)
read_polygon_file <- function(path) {
  ext <- tolower(tools::file_ext(path))
  
  # zipped shapefile: use the first .shp found
  if (ext == "zip") {
    td <- tempfile("polyzip_")
    dir.create(td, recursive = TRUE, showWarnings = FALSE)
    utils::unzip(path, exdir = td)
    
    shp <- list.files(td, pattern = "\\.shp$", recursive = TRUE, full.names = TRUE, ignore.case = TRUE)
    if (length(shp) == 0) {
      logger.warn("The .zip file contains no .shp file.")
      return(NULL)
    }
    if (length(shp) > 1) {
      logger.warn("The .zip file contains %d shapefiles; only '%s' is used.", length(shp), basename(shp[1]))
    }
    
    poly <- tryCatch(sf::read_sf(shp[1]), error = function(e) {
      logger.warn("The shapefile could not be read: %s", conditionMessage(e))
      NULL
    })
    return(poly)
  }
  
  # GeoPackage: use the first layer that contains only polygons
  if (ext == "gpkg") {
    layers <- tryCatch(sf::st_layers(path)$name, error = function(e) {
      logger.warn("The GeoPackage could not be read: %s", conditionMessage(e))
      NULL
    })
    
    for (lyr in layers) {
      obj <- tryCatch(sf::read_sf(path, layer = lyr), error = function(e) {
        logger.warn("GeoPackage layer '%s' could not be read: %s", lyr, conditionMessage(e))
        NULL
      })
      if (is.null(obj) || !inherits(obj, "sf") || nrow(obj) == 0) next
      
      gtypes <- unique(as.character(sf::st_geometry_type(obj)))
      if (all(gtypes %in% c("POLYGON", "MULTIPOLYGON"))) {
        logger.info("Using polygon layer '%s' of the GeoPackage.", lyr)
        return(obj)
      }
    }
    
    logger.warn("The GeoPackage contains no layer with only POLYGON/MULTIPOLYGON geometries.")
    return(NULL)
  }
  
  NULL
}

### helper 2: normalize and validate boundary geometry
normalize_boundary <- function(poly) {
  if (is.null(poly) || nrow(poly) == 0) return(NULL)
  
  poly <- tryCatch(sf::st_make_valid(poly), error = function(e) {
    logger.warn("Polygon geometries could not be repaired, using them as they are: %s", conditionMessage(e))
    poly
  })
  
  if (is.na(sf::st_crs(poly))) {
    logger.warn("The polygon file has no coordinate reference system. Assuming EPSG:4326 (WGS84 longitude/latitude).")
    sf::st_crs(poly) <- 4326
  }
  
  poly <- sf::st_transform(poly, 4326)
  
  gtypes <- unique(as.character(sf::st_geometry_type(poly)))
  if (!all(gtypes %in% c("POLYGON", "MULTIPOLYGON"))) {
    logger.warn("Boundary geometries must be POLYGON or MULTIPOLYGON, found: %s", paste(gtypes, collapse = ", "))
    return(NULL)
  }
  
  if ("shape_id" %in% names(poly)) {
    logger.warn("The existing column 'shape_id' of the polygon file is replaced by the polygon row number.")
  }
  poly$shape_id <- seq_len(nrow(poly))
  poly
}

### helper 3: build flagged points table (coordinates in EPSG:4326)
build_flagged_table <- function(d_ll, within, shape_ids, track_col) {
  xy <- matrix(NA_real_, nrow = nrow(d_ll), ncol = 2)
  not_empty <- !sf::st_is_empty(d_ll)
  if (any(not_empty)) {
    xy[not_empty, ] <- sf::st_coordinates(sf::st_geometry(d_ll)[not_empty])[, 1:2, drop = FALSE]
  }
  
  data.frame(
    track_id = as.character(d_ll[[track_col]]),
    longitude = xy[, 1],
    latitude = xy[, 2],
    timestamp = as.character(mt_time(d_ll)),
    flag = ifelse(within == 1, "inside", "outside"),
    shape_id = shape_ids,
    stringsAsFactors = FALSE
  )
}

############ Main function ##############

rFunction = function(data, ...) {
  
  if (is.null(data) || nrow(data) == 0) {
    logger.info("Input is NULL or has 0 rows. Returning NULL.")
    return(NULL)
  }
  
  if (is.na(sf::st_crs(data))) {
    stop("The input data have no coordinate reference system, so they cannot be compared with the polygon boundary.")
  }
  
  track_col <- mt_track_id_column(data)
  
  polygon_path <- getAuxiliaryFilePath("polygon")
  
  if (is.null(polygon_path) || !file.exists(polygon_path)) {
    logger.info("No polygon file found (neither uploaded nor fallback). Returning input data unchanged.")
    logger.warn("Please upload a polygon file (.zip shapefile or .gpkg) in the App settings.")
    return(data)
  }
  
  logger.info("Using polygon file '%s'.", basename(polygon_path))
  
  if (!tolower(tools::file_ext(polygon_path)) %in% c("zip", "gpkg")) {
    logger.info("Invalid polygon file. Only .zip (shapefile) and .gpkg are supported. Returning input data unchanged.")
    return(data)
  }
  
  boundary_sf <- normalize_boundary(read_polygon_file(polygon_path))
  
  if (is.null(boundary_sf)) {
    logger.info("No valid polygon boundary found. Returning input data unchanged.")
    return(data)
  }
  
  # classification is done on a copy in the polygon CRS (EPSG:4326); the output keeps the input CRS
  data_ll <- if (sf::st_crs(data) == sf::st_crs(boundary_sf)) data else sf::st_transform(data, sf::st_crs(boundary_sf))
  
  keep <- !sf::st_is_empty(data_ll)
  within <- rep(NA_integer_, nrow(data))
  shape_ids <- rep(NA_character_, nrow(data))
  
  if (any(keep)) {
    hits <- sf::st_within(data_ll[keep, ], boundary_sf)
    within[keep] <- as.integer(lengths(hits) > 0)
    shape_ids[keep] <- vapply(hits, function(idx) {
      paste(boundary_sf$shape_id[idx], collapse = ",")
    }, character(1))
  }
  
  logger.info("%d locations inside, %d outside, %d without coordinates.",
              sum(within == 1, na.rm = TRUE), sum(within == 0, na.rm = TRUE), sum(is.na(within)))
  
  # output data: input with one extra column 'within'
  if ("within" %in% names(data)) {
    logger.warn("The existing column 'within' of the input data is overwritten.")
  }
  data$within <- within
  data_ll$within <- within
  
  # flagged table artefact
  flagged_table <- build_flagged_table(data_ll, within, shape_ids, track_col)
  write.csv(flagged_table, appArtifactPath("flagged_points.csv"), row.names = FALSE)
  
  # map artefact
  plot_points <- data_ll[keep, ]
  
  trck_data <- tryCatch(mt_track_lines(plot_points), error = function(e) {
    logger.warn("Track lines could not be added to the map: %s", conditionMessage(e))
    NULL
  })
  
  label_sf <- tryCatch(sf::st_point_on_surface(boundary_sf), error = function(e) {
    logger.warn("Polygon labels could not be added to the map: %s", conditionMessage(e))
    NULL
  })
  if (!is.null(label_sf) && nrow(label_sf) > 0) {
    label_sf$poly_label <- paste("Polygon", label_sf$shape_id)
  }
  
  qc_plot <- ggplot() +
    geom_sf(data = boundary_sf, fill = "grey85", color = "black", linewidth = 0.4) +
    geom_sf(data = plot_points, aes(color = factor(within)), size = 0.8, alpha = 0.8) +
    scale_color_manual(
      values = c("0" = "red", "1" = "darkgreen"),
      labels = c("0" = "Outside", "1" = "Inside"),
      name = "Point status"
    ) +
    labs(x = "Longitude", y = "Latitude",
         title = "Geofence classification check"
    ) +
    theme_bw()
  
  if (!is.null(trck_data) && nrow(trck_data) > 0) {
    qc_plot <- qc_plot +
      geom_sf(data = trck_data, color = "steelblue", linewidth = 0.4, alpha = 0.7)
  }
  
  if (!is.null(label_sf) && nrow(label_sf) > 0) {
    qc_plot <- qc_plot +
      geom_sf_text(data = label_sf, aes(label = poly_label), size = 3)
  }
  
  bb <- sf::st_bbox(c(
    sf::st_geometry(boundary_sf),
    sf::st_geometry(plot_points)
  ))
  
  aeqd <- sprintf(
    "+proj=aeqd +lat_0=%f +lon_0=%f +datum=WGS84 +units=m",
    (bb[["ymin"]] + bb[["ymax"]]) / 2,
    (bb[["xmin"]] + bb[["xmax"]]) / 2
  )
  
  qc_plot <- qc_plot + coord_sf(crs = aeqd)
  
  ggsave(appArtifactPath("geofence_check.png"), plot = qc_plot, width = 9, height = 6, units = "in", dpi = 300)
  
  return(data)
}