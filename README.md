# Geofence

MoveApps

Github repository: *https://github.com/nilanjanchatterjee/Geofence*

## Description
This App classifies animal tracking locations as inside or outside a user-provided polygon boundary, uploaded as a zipped shapefile (.zip) or a GeoPackage (.gpkg). The App returns the full input data with an additional `within` column and creates a CSV table of the classification and a PNG plot for visually checking the result.

## Documentation
This App applies a geofence to animal tracking data. The polygon boundary (one or several polygons) is taken from the file uploaded in the App settings, either as a zipped shapefile (.zip) or a GeoPackage (.gpkg). No default polygon is provided: if no file is uploaded, the App returns the input data unchanged and asks the user in the log to upload a polygon file.

The polygon geometries are repaired if invalid and transformed to WGS84 (EPSG:4326). Each tracking location is then checked against all polygons and classified as inside or outside. A location counts as inside if it lies within at least one polygon; locations lying exactly on a polygon edge are classified as outside.

The returned dataset contains all input locations with an additional `within` column, in which `1` indicates that the location is inside and `0` that it is outside the polygon(s). The output data keep the coordinate reference system of the input data.

The App also creates a CSV table with the classification of every location and a PNG quality-control plot showing the polygon boundary, tracking locations, track lines and inside/outside classification.

### Application scope
#### Generality of App usability
This App was developed for any taxonomic group.

#### Required data properties
The App should work for any kind of (location) data. The input data need a coordinate reference system, and the polygon boundary should overlap with the tracking data.

### Input type
`move2::move2_loc`

### Output type
`move2::move2_loc`

### Artefacts
The following artefacts are created when a valid polygon boundary is used:

`flagged_points.csv`: table with one row per location, containing `track_id`, `longitude` and `latitude` (WGS84), `timestamp`, `flag` (`inside`/`outside`) and `shape_id` (row number(s) of the polygon(s) containing the location, comma separated; empty if outside). Locations without coordinates have `NA` in the coordinate, `flag` and `shape_id` columns.

`geofence_check.png`: map showing the polygon boundary (labelled "Polygon" + `shape_id`), track lines and locations coloured by inside/outside classification. It helps to visually confirm that the classification is correct. The map is drawn in an azimuthal equidistant projection centred on the data, so polygons appear with their true shape on the ground (e.g. a rectangle drawn on a web map may appear slightly trapezoidal). Some locations close to a polygon border may look slightly misplaced because of the point size, but their classification in the output data and the table is correct.

### Settings
`Polygon boundary file` (polygon): one file containing the polygon boundary, either a zipped shapefile (`.zip`, containing at least `.shp`, `.shx`, `.dbf` and preferably `.prj`) or a GeoPackage (`.gpkg`). If the `.zip` contains several shapefiles, only the first one is used; in a GeoPackage, the first layer containing only polygons is used. There is no default; if no file is uploaded, the input data are returned unchanged.

### Changes in output data
The App adds to the input data the column `within`. It contains the geofence result for each location: `1` = inside, `0` = outside, `NA` = location without coordinates. All locations and the coordinate reference system of the input data are kept. If the input data already contain a column `within`, it is overwritten (a warning is written to the log).

If no valid polygon boundary is available, the input data remain unchanged (no `within` column is added).

### Errors and null handling
**Input data:** If the input data are NULL or contain no locations, the App returns NULL. If the input data have no coordinate reference system, the App stops with an error.

**No polygon file uploaded:** a warning asks the user to upload a polygon file; the input data are returned unchanged and no artefacts are created.

**Invalid file type:** only `.zip` (shapefile) and `.gpkg` files are supported; otherwise the input data are returned unchanged and no artefacts are created.

**No valid polygon boundary found:** if the file cannot be read, the `.zip` contains no shapefile, the GeoPackage has no layer with only polygons, or the geometries are not POLYGON/MULTIPOLYGON, the reason is written to the log and the input data are returned unchanged without artefacts.

**Polygon file without coordinate reference system:** the polygons are assumed to be in WGS84 (EPSG:4326) and a warning is written to the log. Make sure your file contains a `.prj` (shapefile) or a defined CRS (GeoPackage) if it is in another projection.

**Locations near polygon edges:** the App treats polygon edges as great-circle lines (shortest path on the globe). For large polygons with few vertices, e.g. rectangles drawn on web maps such as Leaflet, edges therefore bend towards the pole compared with the map display, and locations close to an edge may be classified differently than they appear on the map.

**Common error:** If no locations are classified as inside, check that the polygon boundary overlaps with the tracking data and that its coordinate reference system is defined correctly.

### Technical details
- The classification uses `sf::st_within()` on the whole dataset at once; for longitude/latitude data, `sf` uses spherical geometry (s2), so polygon edges are great-circle lines.
- Polygons are repaired with `sf::st_make_valid()` and transformed to EPSG:4326. The input data are transformed to the polygon CRS for the classification only; the returned data keep their original CRS.
- `shape_id` is the row number of each polygon in the boundary file; an existing `shape_id` column in the file is replaced (warning in the log).
- The PNG map is made with `ggplot2` in an azimuthal equidistant (AEQD) projection centred on the bounding box of the polygons and locations (9 × 6 inches, 300 dpi). Track lines are built with `move2::mt_track_lines()`; if they cannot be built, the map is created without them.