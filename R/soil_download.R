#' .. content for \description{} (no empty lines) ..
#'
#' .. content for \details{} ..
#'
#' @title
#' @param 
#' @return
#' @author Whitney Bagge
#' @export
soil_download <- function(soil_directory_raw) {
  
  options(timeout=200)
  
  location <- c("soil_database", "soil_raster")
  
  for(loc in location){ 
    
   url_out<- switch(loc,  "soil_raster" = "https://s3.eu-west-1.amazonaws.com/data.gaezdev.aws.fao.org/HWSD/HWSD2_RASTER.zip", 
                          "soil_database" = "https://www.isric.org/sites/default/files/HWSD2.sqlite")

   file_ext<- switch(loc,"soil_raster" = ".zip", "soil_database" = ".sqlite")
   
   filename <- paste("data/soil/", loc, file_ext, sep="")
   
   download.file(url=url_out, destfile = filename)
   
   if (loc == "soil_raster" ){
    unzip(filename, exdir = "data/soil/")
   }

  }
  
  return(soil_directory_raw)
  

}

