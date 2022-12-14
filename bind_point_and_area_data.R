
library(readr)
library(dplyr)
library(tidyr)
library(tibble)
library(jsonlite)
library(XML)
library(fastDummies)
library(magrittr)

# Spatial Packages
library(sf)
library(stars)
library(terra)
library(raster)

library(sp)
library(geojsonsf)
library(corrplot)
library(leaflet)
# Graph Plotting
library(ggplot2)
library(ggridges)
library(ggExtra)
library(RColorBrewer)

library(parallel)
library(foreach)
library(doParallel)


library(optparse)


opt <- list()
opt$directory <- "./"
opt$ncors <- 7
my.cluster <- parallel::makeCluster(
  opt$ncores)
doParallel::registerDoParallel(cl = my.cluster)



# Defining Functions ------------------------------------------------------

#' Read and Transform EE DF
#'
#' Read and transform data downloaded
#' from google earth engine.
#' 
#'
#' @param file_name The name of the file to be downloaded (not the entire path)
#' @param basepath The folder where we find the file (relative to current working directory)
#' @param categorical Whether or not the variable is categorical or not
#' @param band_name If the variable is categorical, the name of the band you would like in your output
#'
#' @return
#' @export
#'
#' @examples
read_and_tranform_ee_df <- function(file_name,
                                    basepath = 'data/earth-engine/',
                                    categorical=FALSE,
                                    band_name=NULL){
  
  df <- readr::read_csv(paste0(basepath,file_name))
  
  # Removing unnecessary column names
  if (".geo" %in% colnames(df)){
    df[".geo"] <- NULL
  }
  if ("system:index" %in% colnames(df)){
    df["system:index"] <- NULL
  }
  
  # In the case where we need to 
  # extract categorical band info
  if (categorical==T){
    freq_vector <- df$pixelFrequency
    
    
    freq_vector <- gsub("=", '":', freq_vector)
    freq_vector <- gsub("{", '{"', freq_vector, fixed=T)
    freq_vector <- gsub(", ", ',"', freq_vector, fixed=T)
    
    freq_df <- lapply(freq_vector, function(item){
      fromJSON(item) %>% tibble::as.tibble()
      
    }) %>% dplyr::bind_rows()
    
    if (all(!is.na(as.numeric(colnames(freq_df))))){
      sorted_colnames <- sort(as.numeric(colnames(freq_df)), index.return = T)
      sorted_index <- sorted_colnames$ix
      
      freq_df <- freq_df[sorted_index]
      
    }
    
    
    if (is.null(band_name)){
      stop("Need to supply a name for the band")
    }
    colnames(freq_df) <- paste0(band_name,"_",colnames(freq_df))
    df$pixelFrequency <- NULL
    df <- df %>% dplyr::bind_cols(freq_df)
    
  }
  
  return(df)
  
}


convert_aez_classes <- function(aez_df,
                                aez_colname, 
                                aez_conversion_tbl){
  
  # aez_df <- rasValue
  # aez_colname <- "AEZ_Classes_57"
  # aez_conversion_tbl <- aez_57_class_conversions
  
  aez_df$index <- c(1:nrow(aez_df))
  
  aez_conversion_tbl$band <- as.integer(aez_conversion_tbl$band)
  aez_df[[aez_colname]] <- as.integer(aez_df[[aez_colname]])
  
  
  
  result <- aez_df %>% merge(aez_conversion_tbl, 
                             by.x=aez_colname, 
                             by.y="band",
                             all.x=T,
                             all.y=F)
  
  result <- result[order(result$index),]
  
  result$name <- result$name %>% 
    tolower() %>% 
    gsub("/", " or ", .) %>% 
    gsub(",", "", .) %>% 
    gsub(";", "", .) %>% 
    gsub(" ", "_", .) %>% 
    gsub("-", "_", .) 
  
  
  
  result <- dummy_cols(result, "name", remove_selected_columns=T)
  colnames(result) <- colnames(result) %>% 
    gsub("name_",paste0(aez_colname,"_"),.)
  
  aez_df$index <- NULL
  
  return(result)
}

convert_aez_column_name <- function(aez_df,
                                    aez_colname_pattern, 
                                    aez_conversion_tbl){
  
  # aez_df <- fao_level_2
  # aez_colname_pattern <- "level_2_aez_33_classes_"
  # aez_conversion_tbl <- aez_33_class_conversions
  
  aez_conversion_tbl$name <- aez_conversion_tbl$name %>% 
    tolower() %>% 
    gsub("/", " or ", .) %>% 
    gsub(",", "", .) %>% 
    gsub(";", "", .) %>% 
    gsub(" ", "_", .) %>% 
    gsub("-", "_", .) 
  
  
  columns_to_convert <- grep(aez_colname_pattern, colnames(aez_df@data), value=T)
  column_indices <- grep(aez_colname_pattern, colnames(aez_df@data))
  new_columns <- c()
  for (column in columns_to_convert){
    original_column <- column
    original_column_suffix <- gsub(aez_colname_pattern, "", original_column)
    if (!is.na(as.numeric(original_column_suffix))){
      new_column_suffix <- aez_conversion_tbl$name[aez_conversion_tbl$band==as.numeric(original_column_suffix)]
      new_column <- paste0(aez_colname_pattern,new_column_suffix)
      new_columns <- c(new_columns,new_column)
    }
    else{
      new_columns <- c(new_columns,column)
    }
    
  }
  
  colnames(aez_df@data)[column_indices] <- new_columns
  
  return(aez_df)
}

read_gee_point_df <- function(lsms_df ,path, var_name){
  gee_df <- readr::read_csv(path)
  lsms_df <- lsms_df %>% 
    merge(gee_df, by.x = "index", by.y = "index", all.x = T)
  lsms_df <- lsms_df[colnames(lsms_df) %in% c("system:index",".geo","farm_size_ha.y")==F]
  colnames(lsms_df) <- gsub("farm_size_ha.x","farm_size_ha",colnames(lsms_df))
  colnames(lsms_df) <- gsub("first",var_name,colnames(lsms_df))
  return(lsms_df)
}

#' Categorical Pixel Counts
#' 
#' Extract pixel coverage per 
#' polygon for different categories
#' 
#' See here for guidance: https://stackoverflow.com/questions/61659966/can-i-extract-raster-pixel-frequencies-polygon-by-polygon-one-at-a-time-and-sa
#'
#' @param polygon_feature The feature containing multiple polygons
#' @param categorical_raster The raster containing categorical outputs
#' @param category_prefix A prefix that you would like to give to column names in your final output
#' @param number_of_features N number of first features (used for testing)
categorical_pixel_counts <- function(polygon_feature, 
                                     categorical_raster, 
                                     category_prefix=NULL,
                                     number_of_features=NULL
                                     
){
  polygon_feature$polygon_index <- c(1:length(polygon_feature))
  
  if(is.null(number_of_features)){
    number_of_features <- length(polygon_feature)
  }
  
  result <- foreach(
    polygon_index = 1:number_of_features, 
    .combine = 'rbind',
    .packages=c('tibble', 'magrittr', 'raster')
  ) %dopar% {
    x <- raster::crop(categorical_raster, polygon_feature[polygon_index,])
    x <- raster::mask(categorical_raster, polygon_feature[polygon_index,])
    
    
    
    sub_result <- unname(freq(x, useNA="no"))[[1]] %>% tibble::as_tibble()
    
    
    sub_result["proportion_coverage"] <- sub_result["count"]/sum(sub_result["count"],na.rm = T)
    sub_result$polygon_index <- polygon_index
    
    if (nrow(sub_result)==0){
      sub_result <- tibble::as_tibble(
        list(
          value="no_valid_pixels",
          proportion_coverage=0,
          count=0,
          polygon_index=polygon_index
          
        )
      )
    }
    if(!is.null(category_prefix)){
      sub_result$value <- paste0(category_prefix,"_",sub_result$value)
    }
    sub_result
  }
  
  result <- tidyr::pivot_wider(result, id_cols = "polygon_index",names_from = "value",values_from = "proportion_coverage",values_fill = 0)
  
  polygon_to_return <-  polygon_feature[1:number_of_features,] %>% merge(result, by="polygon_index")
  polygon_to_return$polygon_index<-NULL
  
  return(polygon_to_return)
}

#' Mean Value Per Polygon
#' 
#' Function for caluclating the mean
#' value from a raster, for a particular
#' polygon
#'
#' @param polygon_feature 
#' @param continuous_raster 
#' @param new_name 
#' @param number_of_features 
#'
#' @return
#' @export
#'
#' @examples
continuous_pixel_stat <- function(polygon_feature,
                                  continuous_raster, 
                                  new_name,
                                  number_of_features=NULL){
  polygon_feature$polygon_index <- c(1:length(polygon_feature))
  
  if(is.null(number_of_features)){
    number_of_features <- length(polygon_feature)
  }
  result <- foreach(
    polygon_index = 1:number_of_features, 
    .combine = 'rbind',
    .packages=c('tibble', 'magrittr', 'raster')
  ) %dopar% {
    x <- raster::crop(continuous_raster, polygon_feature[polygon_index,])
    x <- raster::mask(continuous_raster, polygon_feature[polygon_index,])
    sub_result <- raster::extract(continuous_raster,polygon_feature[polygon_index,], fun=function(i,...){
      mean(i, na.rm=T)
    })
    
    as.numeric(sub_result)
  }
  
  result <- tibble::as_tibble(list(
    polygon_index=c(1:length(result)),
    new_column =as.numeric(result)
  ))
  colnames(result) <- c("polygon_index",new_name)
  
  polygon_to_return <-  polygon_feature[1:number_of_features,] %>% merge(result, by="polygon_index")
  
  return(polygon_to_return)
  
}


# Processing_data ---------------------------------------------------------

point_data_type <- "rhomis"
point_data_path <- "data/rhomis-data/processed_data/processed_data.csv"
gps_lat_col <- "gps_lat"
gps_lon_col <- "gps_lon"


# point_data <- readr::read_csv(point_data_path)



point_data_type <- "lsms"
point_data_path <- "data/lsms/farm-size-all-points.csv"


point_data <- readr::read_csv(paste0(opt$directory,point_data_path), na = c("-999", "999", "NA", "n/a"))
point_data$index <- c(1:nrow(point_data))
gps_lat_col <- "latitude"
gps_lon_col <- "longitude"

point_data <- point_data[!is.na(point_data[[gps_lat_col]]) & !is.na(point_data[[gps_lon_col]]),]
point_data <- st_as_sf(point_data, coords = c(gps_lon_col, gps_lat_col),
                        crs = 4326, agr = "constant", remove = F)



fao_level_2 <- geojson_sf(paste0(opt$directory,'data/earth-engine/fao-gaul-level-2.geojson'))
fao_level_2 <- sf::st_as_sf(x = fao_level_2, wkt = "geometry")
fao_level_2 <-st_set_crs(fao_level_2,'EPSG:4326')
types <- vapply(sf::st_geometry(fao_level_2), function(x) {
  class(x)[2]
}, "")
fao_level_2 <- fao_level_2[types!="GEOMETRYCOLLECTION",]


# Converting GAEZ Rasters -------------------------------------------------

aez_33_classes <- raster::raster(x = paste0(opt$directory,"data/gaez/33_classes.tif"))
rasterToPoints(aez_33_classes)

xml_33_list <-  xmlParse(paste0(opt$directory,'data/aez/LR/aez/aez_v9v2red_5m_ENSEMBLE_rcp2p6_2020s.tif.aux.xml'))
xml_33_list <- xmlToList(xml_33_list)
xml_33_list <- xml_33_list$PAMRasterBand$GDALRasterAttributeTable
xml_33_list <- xml_33_list[names(xml_33_list)=="Row"]


aez_33_class_conversions <- lapply(c(1:length(xml_33_list)), function(index){
  row <- xml_33_list[index]$Row
  names_of_row <- names(row)
  features <- unlist(as.list(as.character(row[names(row)=="F"])))
  features <- c(features,row$.attrs[["index"]])
  feature_names <- paste0("feature_",c(1:length(features)))
  
  
  row_df <- tibble::as_tibble(list(
    var=feature_names,
    value=features
  )) %>% pivot_wider(names_from = "var")
  
  result <- row_df[c("feature_2", "feature_8")]
  colnames(result) <- c("band", "name")
  
  return(result)
})  %>% dplyr::bind_rows()


adjusted_length_growing_period  <- raster(paste0(opt$directory,"data/aez/gaez_v4_57_class/adjusted_length_growing_period.tif"))
adjusted_length_growing_period <- projectRaster(adjusted_length_growing_period,aez_33_classes)


# dixons_farm_categories <- sf::read_sf("./data/dixons-farming-systems/FS/fs_lev_2.shp")
# plot(dixons_farm_categories)



# Point estimates
r_stack <- raster::stack(aez_33_classes,adjusted_length_growing_period)
rasValue=raster::extract(r_stack, lsms_data[c("longitude","latitude")]) %>% tibble::as_tibble()
colnames(rasValue) <- gsub("X33_classes", "AEZ_Classes_33", colnames(rasValue))
rasValue$AEZ_Classes_33 <- as.integer(rasValue$AEZ_Classes_33)
rasValue <- convert_aez_classes(rasValue,
                                "AEZ_Classes_33",
                                aez_33_class_conversions)



by_columns <- c("ADM0_CODE",
                "ADM1_CODE",
                "EXP2_YEAR",
                "ADM0_NAME",
                "ADM1_NAME",
                "ADM2_CODE",
                "ADM2_NAME",
                "DISP_AREA",
                "STATUS",
                "STR2_YEAR",
                "Shape_Area",
                "Shape_Leng")


fao_level_2 <-  fao_level_2 %>% merge(elevation_data, 
                                      by=by_columns, 
                                      all.x=T, 
                                      all.y=F)

fao_level_2 <-  fao_level_2 %>% merge(land_cover_cat, 
                                      by=by_columns, 
                                      all.x=T, 
                                      all.y=F)

fao_level_2 <-  fao_level_2 %>% merge(ndvi_data, 
                                      by=by_columns, 
                                      all.x=T, 
                                      all.y=F)

fao_level_2 <-  fao_level_2 %>% merge(night_lights_data, 
                                      by=by_columns, 
                                      all.x=T, 
                                      all.y=F)

fao_level_2 <-  fao_level_2 %>% merge(pop_density_data, 
                                      by=by_columns, 
                                      all.x=T, 
                                      all.y=F)

fao_level_2 <-  fao_level_2 %>% merge(topographic_diversity_data, 
                                      by=by_columns, 
                                      all.x=T, 
                                      all.y=F)

fao_level_2 <-  fao_level_2 %>% merge(travel_time_health_data, 
                                      by=by_columns, 
                                      all.x=T, 
                                      all.y=F)



st_write(fao_level_2, paste0(opt$directory,"data/prepared-data/fao_level_2.geojson"))




