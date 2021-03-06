source(here::here("lib", "common.R"))

load_raw <- function(raw_data_dir, n_max) {
  loading_problems <- list()
  r <- function(fname, n_max = Inf) {
    tbl <- read_csv(file.path(raw_data_dir, fname), n_max = n_max)
    loading_problems[[fname]] <<- problems(tbl)
    tbl
  }
  stop <- r("stop.csv", n_max)
  search <- r("search.csv")
  search_basis <- r("searchbasis.csv")
  person <- r("person.csv")
  contraband <- r("contraband.csv")
  common_codes <- r("refcommoncode.csv")
  stop_codes <- r("refstopscodenumber.csv")
  
  common_codes_translator <- function(col) {
    translator_from_tbl(
      filter(common_codes, CodeType == col),
      "CommonCode",
      "Description"
    )
  }
  stop_codes_translator <- function(col) {
    translator_from_tbl(
      filter(stop_codes, CodeType == col),
      "CommonCodeNumber",
      "Description"
    )
  }
  tr_race <- common_codes_translator("Race")
  tr_search_basis <- common_codes_translator("SearchBasis")
  tr_action <- stop_codes_translator("Action")
  tr_search_type <- stop_codes_translator("SearchType")
  tr_stop_purpose <- stop_codes_translator("StopPurpose")
  tr_county <- translator_from_tbl(
    r("county_codes.csv"),
    "county_id",
    "county_name"
  )
  tr_district <- translator_from_tbl(
    r("district_county_mapping.csv"),
    "district",
    "county_name"
  )

  # NOTE: D is Driver and P is Passenger, see refcommoncode.csv;
  # drop Type as well, since it's now useless and Type in search.csv
  # corresponds to search type, which we want to keep
  only_drivers <- filter(person, Type == "D") %>% select(-Type)

  # NOTE: there can be multiple search bases per stop-search-person, so we
  # collapse them here
  collapsed_search_basis <-
    group_by(
      search_basis,
      StopID,
      SearchID,
      PersonID
    ) %>%
    mutate(
      Basis = tr_search_basis[Basis]
    ) %>%
    summarize(
      Basis = str_c(Basis, collapse = '|')
    )
  
  # NOTE: the only major caveat with the following data is that the search,
  # search basis, and contraband associated with each stop could be from a
  # Driver or a Passenger (~3.6% of cases), even though we use the Driver for
  # demographic information like race, sex, age, etc

  # NOTE: there is a 1:N correspondence between StopID and PersonID,
  # so we filtered out passengers above to prevent duplicates
  left_join(
    stop,
    only_drivers
  ) %>%
  # NOTE: by not joining search also on PersonID, we are getting the search
  # associated with whomever was searched, Driver or Passenger; curiously,
  # with this data, there is a 1:1 correspondence between StopID and SearchID,
  # (as well as between SearchID and PersonID) meaning that only the Driver or
  # Passenger is associated with the SearchID, even though this has no bearing
  # on DriverSearched and PassengerSearched fields in the search table; in
  # other words, one person from each stop was selected to link the stop and
  # search tables, i.e.
  #
  # StopID, PersonID, Type, SearchID, DriverSearched, PassengerSearched
  # 123   , 1       , D   , NA      , NA            , NA
  # 123   , 2       , P   , 7889,   , 1             , 1
  # 123   , 3       , P   , NA      , NA            , NA
  #
  # SearchID:StopID is 1:1 -->
  # group_by(search, SearchID, StopID) %>% count %>% nrow == nrow(search)
  #
  # j <- group_by(left_join(select(search, -Type), person))
  #
  # SearchID:PersonID is 1:1 -->
  # group_by(j, SearchID, PersonID) %>% count %>% nrow == nrow(search)
  #
  # DriverSearched and PassengerSearched don't depend on whether the PersonID
  # associated with the SearchID was a Driver or Passenger -->
  # group_by(j, Type, DriverSearch, PersonSearch) %>% count
  left_join(
    select(search, -PersonID),
    by = c("StopID")
  ) %>%
  # NOTE: again, not joining also on PersonID here because the search basis is
  # associated with whomever was searched, Driver or Passenger, and here we are
  # focusing on only the Drivers to remove duplicates; so this will be the
  # search basis associated with the SearchID above:
  #
  # There are not multiple people associated with each <StopID,SearchID> -->
  # group_by(search_basis, StopID, SearchID, PersonID) %>% count %>% nrow
  # group_by(search_basis, StopID, SearchID) %>% count %>% nrow
  #
  # There are, however, multiple SearchBasisIDs per <StopID,SearchID>, so
  # we collapsed those above
  left_join(
    select(collapsed_search_basis, -PersonID),
    by = c("StopID", "SearchID")
  ) %>%
  # NOTE: same reasoning as above, except there is only one ContrabandID per
  # <StopID, SearchID> -->
  # group_by(contraband, StopID, SearchID) %>% count %>% nrow
  # group_by(contraband, StopID, SearchID, ContrabandID) %>% count %>% nrow
  left_join(
    select(contraband, -PersonID),
    by = c("StopID", "SearchID")
  ) %>%
  mutate(
    race_description = tr_race[Race],
    action_description = tr_action[Action],
    search_type_description = tr_search_type[Type], 
    stop_purpose_description = tr_stop_purpose[Purpose],
    county_name = tr_county[StopLocation],
    # NOTE: Map length-2 county district codes to county name, and normalize
    # non-mapped names
    county_name = if_else(
      str_length(county_name) == 2, 
      tr_district[county_name],
      str_c(county_name, " County")
    )
  ) %>%
  bundle_raw(loading_problems)
}


clean <- function(d, helpers) {

  gt_0 <- function(col) { !is.na(col) & col > 0 }

  d$data %>%
  rename(
    department_name = AgencyDescription,
    officer_id = OfficerId,
    reason_for_search = Basis,
    reason_for_stop = stop_purpose_description,
    search_vehicle = VehicleSearch,
    subject_age = Age
  ) %>%
  mutate(
    # NOTE: all persons are either Drivers or Passengers (no Pedestrians)
    type = "vehicular",
    datetime = parse_datetime(StopDate),
    date = as.Date(datetime),
    time = format(datetime, "%H:%M:%S"),
    # NOTE: the majority of times are midnight, which signify missing data
    time = if_else(time == "00:00:00", NA_character_, time),
    # TODO(phoebe): can we get better location data?
    # https://app.asana.com/0/456927885748233/635930602677956
    location = str_c_na(
      StopCity,
      county_name,
      sep = ", "
    ),
    arrest_made = str_detect(action_description, "Arrest"),
    citation_issued = str_detect(action_description, "Citation"),
    warning_issued = str_detect(action_description, "Warning"),
    # NOTE: a small percentage of these are "No Action Taken" which will
    # be coerced to NAs during standardization
    outcome = first_of(
      "arrest" = arrest_made,
      "citation" = citation_issued,
      "warning" = warning_issued
    ),
    subject_race = tr_race[if_else(Ethnicity == "H", "H", Race)],
    subject_sex = tr_sex[Gender],
    search_conducted = !is.na(SearchID),
    search_person = as.logical(DriverSearch) | as.logical(PassengerSearch),
    frisk_performed = if_else_na(
      search_type_description == "Protective Frisk",
      T,
      F
    ),
    # NOTE: in standardize, this will be set to NA if a frisk wasn't conducted
    reason_for_frisk = reason_for_search,
    search_basis = first_of(
      "consent" = search_type_description == "Consent",
      "probable cause" = search_type_description == "Probable Cause",
      "other" = str_detect(
        search_type_description,
        "Search Incident to Arrest|Search Warrant"
      )
    ),
    # NOTE: if ContrabandID is not null, contraband was found
    contraband_found = !is.na(ContrabandID),
    # TODO(phoebe): what are "gallons" and "pints" typically of?
    # https://app.asana.com/0/456927885748233/635930602677955
    contraband_drugs =
      gt_0(Ounces)
      | gt_0(Pounds)
      | gt_0(Kilos)
      | gt_0(Grams)
      | gt_0(Dosages),
    contraband_weapons = gt_0(Weapons),
  ) %>%
  rename(
    raw_ethnicity = Ethnicity,
    raw_race = Race,
    raw_driver_search = DriverSearch,
    raw_passenger_search = PassengerSearch,
    raw_action_description = action_description,
    raw_search_type_description = search_type_description,
    raw_dollar_amount = DollarAmt,
    raw_dosages = Dosages,
    raw_gallons = Gallons,
    raw_grams = Grams,
    raw_kilos = Kilos,
    raw_money = Money,
    raw_ounces = Ounces,
    raw_pints = Pints,
    raw_pounds = Pounds,
    raw_weapons = Weapons,
    raw_encounter_force = EncounterForce,
    raw_engage_force = EngageForce
  ) %>%
  standardize(d$metadata)
}
