
# This is going to be dynamic branching over list of dates. Then a target to convert to raster stacks, one for parquet, and one for animation
get_daily_outbreak_history <- function(dates_df,
                                       wahis_outbreaks,
                                       wahis_distance_matrix,
                                       wahis_raster_template,
                                       output_dir = "data/outbreak_history_dataset",
                                       output_filename = "outbreak_history.tif",
                                       save_parquet = T,
                                       beta_time = 0.5,
                                       max_years = 10,
                                       recent = 3/12) {
  
  if(!grepl("(tif|tiff|nc|asc)", tools::file_ext(output_filename))) stop("output_filename extension must be .tif, .tiff, .nc, or .asc!")
  
  # Create directory if it does not yet exist
  dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
  
  wahis_raster_template <- terra::unwrap(wahis_raster_template)
  
  daily_outbreak_history <- map_dfr(dates_df$date, ~get_outbreak_history(date = .x,
                                                                         wahis_outbreaks,
                                                                         wahis_distance_matrix,
                                                                         wahis_raster_template,
                                                                         beta_time = beta_time,
                                                                         max_years = max_years,
                                                                         recent = recent))
  
  daily_recent_outbreak_history <- terra::rast(daily_outbreak_history$recent_outbreaks_rast)
  daily_old_outbreak_history <- terra::rast(daily_outbreak_history$old_outbreaks_rast)
  
  recent_output_filename <- paste0(output_dir, "/", tools::file_path_sans_ext(output_filename), "_recent_", dates_df$year[1], ".", tools::file_ext(output_filename))
  recent <- as.data.frame(daily_recent_outbreak_history, xy = TRUE) |> as_tibble()
  arrow::write_parquet(recent, paste0(tools::file_path_sans_ext(recent_output_filename), ".parquet"), compression = "gzip", compression_level = 5)
  terra::writeRaster(daily_recent_outbreak_history, filename = recent_output_filename, overwrite=T, gdal=c("COMPRESS=LZW"))
  
  old_output_filename <- paste0(output_dir, "/", tools::file_path_sans_ext(output_filename), "_old_", dates_df$year[1], ".", tools::file_ext(output_filename))
  old <- as.data.frame(daily_old_outbreak_history, xy = TRUE) |> as_tibble()
  arrow::write_parquet(old, paste0(tools::file_path_sans_ext(old_output_filename), ".parquet"), compression = "gzip", compression_level = 5)
  terra::writeRaster(daily_old_outbreak_history, filename = old_output_filename, overwrite=T, gdal=c("COMPRESS=LZW"))
  
  c(recent_output_filename, old_output_filename)
  
}

#' Get the outbreak history for a given day
#'
#' @param date 
#' @param wahis_outbreaks 
#' @param wahis_distance_matrix 
#' @param wahis_raster_template 
#' @param beta_time 
#' @param max_years 
#' @param recent 
#'
#' @return
#' @export
#'
#' @examples
get_outbreak_history <- function(date,
                                 wahis_outbreaks, 
                                 wahis_distance_matrix,
                                 wahis_raster_template,
                                 beta_time = 0.5,
                                 max_years = 10,
                                 recent = 1/6) {
  
  message(paste("Extracting outbreak history for", as.Date(date)))
  
  outbreak_history <- wahis_outbreaks |> 
    arrange(outbreak_id) |>
    mutate(end_date = pmin(date, end_date, na.rm = T),
           years_since = as.numeric(as.duration(date - end_date), "years")) |>
    filter(date > end_date, years_since < max_years & years_since >= 0) |>
    mutate(time_weight = ifelse(is.na(cases), 1, log10(cases + 1))*exp(-beta_time*years_since))
  
  old_outbreaks <- outbreak_history |> filter(years_since >= recent) |> 
    combine_weights(wahis_distance_matrix, wahis_raster_template) |> setNames(as.Date(date))
  
  recent_outbreaks <- outbreak_history |> filter(years_since < recent) |> 
    combine_weights(wahis_distance_matrix, wahis_raster_template) |> setNames(as.Date(date))
  
  tibble(date = as.Date(date), 
         recent_outbreaks_rast = list(recent_outbreaks),
         old_outbreaks_rast = list(old_outbreaks))
}

#' Combining time and distance weights.
#' Optimized for speed.
#'
#' @param outbreaks 
#' @param wahis_distance_matrix 
#' @param wahis_raster_template 
#'
#' @return
#' @export
#'
#' @examples
combine_weights <- function(outbreaks, 
                            wahis_distance_matrix, 
                            wahis_raster_template) {
 
  if(!nrow(outbreaks)) {
    wahis_raster_template[!is.na(wahis_raster_template)] <- 0
    return(wahis_raster_template)
  }
  # Multiply time weights by distance weights
  
  # Super fast matrix multiplication step. This is the secret sauce.
  # Performs sweep(outbreaks$time_weight, "*") and rowsums() all in once go
  # and indexes the wahis_distance_matrix (which was calculated only once)
  # instead of re-calculating distances every day. These changes
  # sped it up from needing 7 hours to calculate the daily history for
  # 2010 to doing the same thing in 4.3 minutes.
  weights <- wahis_distance_matrix[,outbreaks$outbreak_id] |>
    as.matrix() |> Rfast::mat.mult(as.matrix(outbreaks$time_weight))
  
  idx <- which(!is.nan(wahis_raster_template[]))
  wahis_raster_template[idx] <- weights
  
  wahis_raster_template
}

#' Calculate a matrix of spatial distance weights between every outbreak 
#' and every cell in the raster template within a given distance
#'
#' @param wahis_outbreaks 
#' @param wahis_raster_template 
#' @param within_km 
#' @param beta_dist 
#'
#' @return
#' @export
#'
#' @examples
get_outbreak_distance_matrix <- function(wahis_outbreaks, wahis_raster_template, within_km = 500, beta_dist = 0.01) {
  
  wahis_raster_template <- wahis_raster_template |> terra::unwrap()
  
  xy <- as.data.frame(wahis_raster_template, xy = TRUE) |> select(y, x) |> rename(longitude = x, latitude = y)
  
  # For each outbreak origin identify the distance to every other point in Africa within `within_km` km
  dist_mat <- geodist::geodist(xy, wahis_outbreaks |> arrange(outbreak_id), measure = "vincenty") # Good enough for our purposes and _much_ faster than s2
  
  # Drop all distances greater than within_km
  # Not sure why we need to do this given choice of beta_dist
  dist_mat[dist_mat > (within_km * 1000)] <- NA
  
  # Calculate a weighting factor based on distance. Note we haven't included log10 cases yet.
  # This is negative exponential decay - points closer to the origin will be 1 and those farther
  # away will be closer to zero mediated by beta_dist.
  dist_mat <- exp(-beta_dist*dist_mat/1000)
  
  # Facilitate matrix math later
  dist_mat[is.na(dist_mat)] <- 0
  
  dist_mat
}

#' Animate a stacked SpatRaster file
#'
#' @param input_files 
#' @param output_dir 
#' @param output_filename 
#' @param layers 
#' @param title 
#' @param ... 
#'
#' @return
#' @export
#'
#' @examples
get_outbreak_history_animation <- function(input_file,
                                           output_dir = "outputs",
                                           num_cores = 1,
                                           ...) {
  
  output_basename = tools::file_path_sans_ext(basename(input_file))
  output_filename = paste0(output_dir, "/", output_basename, ".gif")
  
  # Create temporary directory if it does not yet exist
  tmp_dir <- paste(output_dir, output_basename, sep = "/")
  dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)
  
  message(paste("Animating", output_filename))
  
  # Load the raster
  outbreak_raster <- terra::rast(input_file)
  
  df <- as.data.frame(outbreak_raster, xy=TRUE)
  
  lims <- c(min(select(df, c(-x, -y)), na.rm=T), 
            max(select(df, c(-x, -y)), na.rm=T))
  
  date_indices <- which(names(df) %in% setdiff(names(df), c("x", "y")))
  coordinates <- df |> select(x,y)
  
  title <- stringr::str_split(tools::file_path_sans_ext(basename(input_file)), "_")[[1]] |> 
    head(-1) |> paste(collapse = " ") |> 
    stringr::str_to_title()
  
  png_files <- parallel::mclapply(mc.cores = num_cores, 
                     date_indices, 
                     function(i) plot_outbreak_history(coordinates,
                                                       weights = df[,i],
                                                       date = names(df)[i],
                                                       tmp_dir = tmp_dir,
                                                       title = paste(title, names(df)[i]),
                                                       lims = lims)) |> 
    unlist() |> sort()
  
  # Add in a delay at end before looping back to beginning. This is in frames not seconds
  png_files <- c(png_files, rep(png_files |> tail(1), 50))
  
  # Render the animation
  gif_file <- gifski::gifski(png_files, 
                             delay = 0.04,
                             gif_file = output_filename)
  
  # Clean up temporary files
  unlink(tmp_dir, recursive = T)
  
  # Return the location of the rendered animation
  output_filename
}

plot_outbreak_history <- function(coordinates,
                                  weights, 
                                  date,
                                  tmp_dir,
                                  title = NULL,
                                  lims = NULL) {
  
  filename <- paste0(tmp_dir, "/", date, ".png")
  
  p <- ggplot(coordinates |> mutate(value = weights), aes(x=x, y=y, fill=value)) +
    geom_raster() +
    scale_fill_viridis_c(limits = lims,
                         trans = scales::sqrt_trans()) +
    labs(title = title, x = "Longitude", y = "Latitude", fill = "Weight\n") +
    theme_minimal() +
    theme(text=element_text(size = 18),
          legend.title = element_text(vjust = 0.05)) 
  
  if(!is.null(filename)) {
    png(filename = filename, width = 600, height = 600)
    print(p)
    dev.off()
    return(filename)
  }

  p
}

# test <- get_daily_outbreak_history(dates = dates,
#                                    wahis_rvf_outbreaks_preprocessed = wahis_rvf_outbreaks_preprocessed,
#                                    continent_raster_template = continent_raster_template,
#                                    continent_polygon = continent_polygon)
# 
# get_outbreak_history_animation(daily_old_outbreak_history)