#' .. content for \description{} (no empty lines) ..
#'
#' .. content for \details{} ..
#'
#' @title

#' @return
#' @author Emma Mendelsohn
#' @export
set_ecmwf_api_parameter <- function() {

  # System 4 covers just sept/oct 2017
  sys4 <- tibble(system = 4, year = list(2017), month = list(9:10))
  
  # System 51 covers nov 2022 through present
  sys51_dates <- seq(ymd("2022-11-01"), Sys.Date(), by = "month")
  
  ## Real-time forecasts are released once per month on the 13th at 12UTC
  ## Check if new forecast has been released this month
  current_time <- as.POSIXlt(Sys.time(), tz = "UTC")
  current_year <- year(current_time)
  current_month <- month(current_time)
  update_date <- ymd_hms(paste0(current_year,"-", current_month, "-13 12:00:00"))
  if(current_time < update_date) sys51_dates <- sys51_dates[-length(sys51_dates)]
  
  ## Split into batches of 5 years for download limits (only will be applicable in 2027)
  sys51_years <- unique(year(sys51_dates))
  if(length(sys51_years) > 5){
    sys51_years <- split(sys51_years, ceiling(sys51_years/5))
  }else{
    sys51_years <- list(sys51_years)
  }
  sys51 <- tibble(system = 51,
                  year = sys51_years,
                  month = list(unique(month(sys51_dates))))
  
  # System 5 covers everything else. 
  sys5_years <- 1993:2022
  sys5 <- tibble(system = 5, year = split(sys5_years, ceiling(sys5_years/ 5)), month = list(1:12))
  
  # Tibble to interate over rowwise for download
  seasonal_forecast_parameters <- bind_rows(sys4, sys51, sys5)
  
  return(seasonal_forecast_parameters)

}