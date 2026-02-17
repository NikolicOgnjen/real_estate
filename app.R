# ==============================================================================
# Shiny aplikacija za analizu tržišta nekretnina
# Verzija 2.1 - Debounce za bolje performanse
# ==============================================================================

# --- 1. Učitavanje potrebnih biblioteka ---
library(shiny)
library(shinydashboard)
library(dplyr)
library(plotly)
library(DT)
library(RSQLite)
library(DBI)
library(scales)
library(stringr)
library(ggplot2)




# ==============================================================================
# --- 2. UČITAVANJE I PRIPREMA PODATAKA (Globalni deo) ---
# ==============================================================================

# Funkcija za učitavanje i čišćenje podataka
load_and_clean_data <- function() {
  
  message("Učitavam i čistim podatke...")
  
  base_path <- "." 
  
  con_oglasi <- dbConnect(SQLite(), file.path(base_path, "oglasi.rs_data.db"))
  con_nekretnine_rs <- dbConnect(SQLite(), file.path(base_path, "nekretnine.rs_data.db"))
  
  df_oglasi <- dbReadTable(con_oglasi, "oglasi")
  df_nekretnine_rs <- dbReadTable(con_nekretnine_rs, "oglasi")
  
  dbDisconnect(con_oglasi)
  dbDisconnect(con_nekretnine_rs)
  

  
  df_oglasi_clean <- df_oglasi %>%
    mutate(
      Cena = suppressWarnings(as.numeric(gsub(" EUR", "", gsub(",", ".", gsub("\\.", "", Cena))))),
      Kvadratura = suppressWarnings(as.numeric(gsub("m2", "", Kvadratura))),
      Datum_preuzimanja = as.Date(Datum_preuzimanja),
      Grad = if_else(Grad == "Prodaja stanova", NA_character_, Grad),
      Izvor = "oglasi.rs"
    ) %>%
    group_by(Link) %>%
    arrange(desc(Datum_preuzimanja)) %>%
    slice_head(n = 1) %>%
    ungroup() %>% 
    select(Cena, Kvadratura, Grad, Lokacija, Link, Datum_preuzimanja, Izvor)
  
  df_nekretnine_rs_clean <- df_nekretnine_rs %>%
    mutate(
      Cena = suppressWarnings(as.numeric(gsub("€", "", gsub(" ", "", Cena)))),
      Kvadratura = suppressWarnings(as.numeric(gsub(" m²", "", Kvadratura, fixed = TRUE))),
      Datum_preuzimanja = as.Date(Datum_preuzimanja),
      Izvor = "nekretnine.rs",
      Drzava = str_extract(Lokacija, "(?<=, )[^,]+$"),
      Grad = str_extract(Lokacija, "[^,]+(?=, [^,]+$)"),
      Lokacija = str_extract(Lokacija, ".*(?=, [^,]+, [^,]+$)"),
      Drzava = str_trim(Drzava),
      Grad = str_trim(Grad),
      Lokacija = str_trim(Lokacija)
    ) %>%
    group_by(URL) %>%
    arrange(desc(Datum_preuzimanja)) %>%
    slice_head(n = 1) %>%
    ungroup() %>% 
    select(Cena, Kvadratura, Grad, Lokacija, Link = URL, Datum_preuzimanja, Izvor)
  
  all_data <- rbind(df_oglasi_clean, df_nekretnine_rs_clean)
  
  # NOVO: Stroži filter - uklanjamo nerealne oglase ispod 5.000 € i iznad 1.000.000 €
  all_data_final <- all_data %>%
    filter(
      !is.na(Cena), 
      Cena >= 5000,
      Cena <= 1000000,
      !is.na(Kvadratura), 
      Kvadratura > 10,
      Kvadratura <= 500,
      !is.na(Grad), 
      Grad != ""
    ) %>%
    mutate(
      Cena_po_m2 = round(Cena / Kvadratura),
      Grad = trimws(gsub(" opština| grad", "", Grad))
    )
  
  message("Podaci uspešno učitani i obrađeni!")
  return(all_data_final)
}

all_data <- load_and_clean_data()

# ==============================================================================
# --- 2B. KREIRANJE PREDIKTIVNOG MODELA ---
# ==============================================================================

# Priprema podataka za model
model_data <- all_data %>%
  filter(
    !is.na(Grad),
    !is.na(Lokacija),
    !is.na(Kvadratura),
    !is.na(Cena_po_m2),
    Lokacija != "",
    Grad != ""
  )

predict_price_per_m2 <- function(grad, lokacija = NULL, kvadratura) {
  
  if (!is.null(lokacija) && lokacija != "" && lokacija != "Sve") {
    lokacija_data <- model_data %>%
      filter(Grad == grad, Lokacija == lokacija)
    
    if (nrow(lokacija_data) >= 5) {
      median_price <- median(lokacija_data$Cena_po_m2, na.rm = TRUE)
      q25 <- quantile(lokacija_data$Cena_po_m2, 0.25, na.rm = TRUE)
      q75 <- quantile(lokacija_data$Cena_po_m2, 0.75, na.rm = TRUE)
      
      size_factor <- ifelse(kvadratura < 50, 1.05,
                            ifelse(kvadratura > 100, 0.95, 1.0))
      
      return(list(
        predicted_price_m2 = round(median_price * size_factor),
        lower_bound = round(q25 * size_factor),
        upper_bound = round(q75 * size_factor),
        confidence = "Visoka",
        n_samples = nrow(lokacija_data),
        source = "Specifična lokacija"
      ))
    }
  }
    grad_data <- model_data %>%
    filter(Grad == grad)
  
  if (nrow(grad_data) >= 10) {
    median_price <- median(grad_data$Cena_po_m2, na.rm = TRUE)
    q25 <- quantile(grad_data$Cena_po_m2, 0.25, na.rm = TRUE)
    q75 <- quantile(grad_data$Cena_po_m2, 0.75, na.rm = TRUE)
    size_factor <- ifelse(kvadratura < 50, 1.05,
                          ifelse(kvadratura > 100, 0.95, 1.0))
    return(list(
      predicted_price_m2 = round(median_price * size_factor),
      lower_bound = round(q25 * size_factor),
      upper_bound = round(q75 * size_factor),
      confidence = "Srednja",
      n_samples = nrow(grad_data),
      source = "Grad (prosek)"
    ))
  }
  global_median <- median(model_data$Cena_po_m2, na.rm = TRUE)
  global_q25 <- quantile(model_data$Cena_po_m2, 0.25, na.rm = TRUE)
  global_q75 <- quantile(model_data$Cena_po_m2, 0.75, na.rm = TRUE)
  size_factor <- ifelse(kvadratura < 50, 1.05,
                        ifelse(kvadratura > 100, 0.95, 1.0))
  return(list(
    predicted_price_m2 = round(global_median * size_factor),
    lower_bound = round(global_q25 * size_factor),
    upper_bound = round(global_q75 * size_factor),
    confidence = "Niska",
    n_samples = nrow(model_data),
    source = "Globalni prosek"
  ))
}

message("✅ Prediktivni model kreiran!")



# ==============================================================================
# --- 3. UI (User Interface) ---
# ==============================================================================
ui <- dashboardPage(
  skin = "blue",
  dashboardHeader(title = "Tržište Nekretnina"),
  
  dashboardSidebar(
    width = 350, 
    
    sidebarMenu(
      menuItem("📊 Pregled", tabName = "pregled", icon = icon("dashboard")),
      menuItem("📈 Analiza Gradova", tabName = "analiza_gradova", icon = icon("city")),
      menuItem("📏 Analiza Kvadratura", tabName = "analiza_kvadratura", icon = icon("ruler-combined")),
      menuItem("📊 Statistička Analiza", tabName = "statistika", icon = icon("chart-line")),
      menuItem("🔮 Kalkulator Cene", tabName = "kalkulator", icon = icon("calculator")), 
      menuItem("📋 Agregirani Prikaz", tabName = "tabela", icon = icon("table"))
    ),
    hr(),
    h4("Filteri:", style = "padding-left: 15px;"),
    
    selectInput("filter_izvor", "Izvor podataka:",
                choices = c("Svi", unique(all_data$Izvor)),
                selected = "Svi",
                multiple = TRUE),
    
    selectInput("filter_grad", "Grad:",
                choices = c("Svi", sort(unique(all_data$Grad))),
                selected = "Svi",
                multiple = TRUE),

    tags$div(style = "padding: 10px 15px;",
             tags$label("Cena (€):", style = "font-weight: bold; margin-bottom: 5px; display: block;"),
             fluidRow(
               column(6, 
                      numericInput("filter_cena_min", "Minimum:",
                                   value = 5000,
                                   min = 5000,
                                   max = 1000000,
                                   step = 5000,
                                   width = "100%")
               ),
               column(6,
                      numericInput("filter_cena_max", "Maximum:",
                                   value = 500000,
                                   min = 5000,
                                   max = 1000000,
                                   step = 5000,
                                   width = "100%")
               )
             )
    ),
    
  
    tags$div(style = "padding: 10px 15px;",
             tags$label("Kvadratura (m²):", style = "font-weight: bold; margin-bottom: 5px; display: block;"),
             fluidRow(
               column(6,
                      numericInput("filter_kvadratura_min", "Minimum:",
                                   value = 10,
                                   min = 10,
                                   max = 500,
                                   step = 5,
                                   width = "100%")
               ),
               column(6,
                      numericInput("filter_kvadratura_max", "Maximum:",
                                   value = 300,
                                   min = 10,
                                   max = 500,
                                   step = 5,
                                   width = "100%")
               )
             )
    ),
    
    tags$div(style = "padding: 15px; text-align: center;",
             actionButton("reset_filters", "Resetuj Filtere", 
                          icon = icon("refresh"),
                          style = "width: 100%; background-color: #3c8dbc; color: white; border: none; padding: 10px;")
    )
  ),
  
  dashboardBody(
    tags$head(
      tags$style(HTML("
        .sidebar-menu {
          white-space: normal;
        }
        
        .form-group {
          margin-bottom: 10px;
        }
        
        @media (max-width: 768px) {
          .main-sidebar {
            width: 250px;
          }
        }
      "))
    ),
    
    tabItems(
      # TAB 1: Pregled
      tabItem(tabName = "pregled",
              fluidRow(
                valueBoxOutput("box_ukupno_oglasa", width = 3),
                valueBoxOutput("box_medijan_cena", width = 3),
                valueBoxOutput("box_medijan_kvadratura", width = 3),
                valueBoxOutput("box_medijan_cena_po_m2", width = 3)
              ),
              fluidRow(
                box(title = "Broj Oglasa po Izvoru", status = "primary", solidHeader = TRUE, width = 6, 
                    plotlyOutput("plot_izvor")),
                box(title = "Broj Oglasa po Gradu (Top 10)", status = "primary", solidHeader = TRUE, width = 6, 
                    plotlyOutput("plot_grad_top10"))
              )
      ),
      
      # ... OSTALI TABOVI OSTAJU ISTI ...
      # TAB 2: Analiza Gradova
      tabItem(tabName = "analiza_gradova",
              fluidRow(
                box(title = "Medijan Cena po m² po Gradu (Top 15)", status = "primary", solidHeader = TRUE, width = 12, 
                    plotlyOutput("plot_grad_cena_m2"))
              )
      ),
      
      # ===========================================================================
      # TAB 3: ANALIZA KVADRATURA - ISPRAVLJENO
      # ===========================================================================
      
      # U UI delu - OSTAJE ISTO
      tabItem(tabName = "analiza_kvadratura",
              # Red 1: Glavni grafik
              fluidRow(
                box(
                  title = "Medijan Cena po m² po Kategoriji Kvadrature - Svi Gradovi", 
                  status = "primary", 
                  solidHeader = TRUE, 
                  width = 12,
                  plotlyOutput("plot_kvadratura_grupe")
                )
              ),
              
              # Red 2: Selector za gradove
              fluidRow(
                box(
                  title = "Analiza po Gradovima", 
                  status = "info", 
                  solidHeader = TRUE, 
                  width = 12,
                  
                  selectInput("kvadratura_gradovi", 
                              "Izaberite gradove za detaljnu analizu:",
                              choices = NULL,  # Popuniće se dinamički
                              selected = NULL,
                              multiple = TRUE),
                  
                  tags$p(
                    style = "color: #666; font-size: 0.9em;",
                    "💡 Savet: Izaberite do 4 grada za najbolji prikaz"
                  )
                )
              ),
              
              # Red 3: Dinamički grafici
              fluidRow(
                uiOutput("plot_kvadratura_po_gradu_ui")
              )
      ),
      
      # TAB 4: STATISTIČKA ANALIZA
      tabItem(tabName = "statistika",
              # Red 1: Percentili
              fluidRow(
                valueBoxOutput("box_percentil_25", width = 3),
                valueBoxOutput("box_percentil_50", width = 3),
                valueBoxOutput("box_percentil_75", width = 3),
                valueBoxOutput("box_korelacija", width = 3)
              ),
              
              # Red 2: Histogram i Box Plot
              fluidRow(
                box(
                  title = "Distribucija Cena po m²", 
                  status = "primary", 
                  solidHeader = TRUE, 
                  width = 6,
                  plotlyOutput("plot_histogram", height = "350px")
                ),
                box(
                  title = "Box Plot po Gradovima (Top 10)", 
                  status = "primary", 
                  solidHeader = TRUE, 
                  width = 6,
                  plotlyOutput("plot_boxplot", height = "350px")
                )
              ),
              
              # Red 3: Scatter Plot
              fluidRow(
                box(
                  title = "Korelacija: Kvadratura vs Cena", 
                  status = "primary", 
                  solidHeader = TRUE, 
                  width = 12,
                  plotlyOutput("plot_scatter", height = "400px")
                )
              ),
              
              # Red 4: Outliers Tabele
              fluidRow(
                box(
                  title = "🟢 Ekstremno Jeftine Nekretnine (< 5. percentil)", 
                  status = "success", 
                  solidHeader = TRUE, 
                  width = 6,
                  DTOutput("tabela_jeftine")
                ),
                box(
                  title = "🔴 Ekstremno Skupe Nekretnine (> 95. percentil)", 
                  status = "danger", 
                  solidHeader = TRUE, 
                  width = 6,
                  DTOutput("tabela_skupe")
                )
              )
      ),
      
      # TAB 5: KALKULATOR CENE (NOVO!)
      tabItem(tabName = "kalkulator",
              fluidRow(
                # Levi deo - Inputi
                box(
                  title = "🔮 Procena Fer Cene Nekretnine", 
                  status = "primary", 
                  solidHeader = TRUE, 
                  width = 4,
                  
                  selectInput("calc_grad", "Izaberite grad:",
                              choices = c("", sort(unique(all_data$Grad))),
                              selected = ""),
                  
                  uiOutput("calc_lokacija_ui"),
                  
                  numericInput("calc_kvadratura", "Kvadratura (m²):",
                               value = 60,
                               min = 10,
                               max = 500,
                               step = 5),
                  
                  actionButton("calc_predict", "Izračunaj Procenu", 
                               icon = icon("calculator"),
                               style = "width: 100%; background-color: #00a65a; color: white; border: none; padding: 10px; font-weight: bold;"),
                  
                  hr(),
                  
                  uiOutput("prediction_results")
                ),
                
                # Desni deo - Info
                box(
                  title = "📊 Kako funkcioniše?", 
                  status = "info", 
                  solidHeader = TRUE, 
                  width = 8,
                  
                  tags$h4("Model za predviđanje cene"),
                  tags$p("Ovaj jednostavni model koristi medijan cena iz realne tržišne baze podataka."),
                  
                  tags$h5("📈 Tri nivoa pouzdanosti:"),
                  tags$ul(
                    tags$li(tags$strong("Visoka:"), " Imamo 5+ oglasa za tačno tu lokaciju"),
                    tags$li(tags$strong("Srednja:"), " Imamo 10+ oglasa za grad"),
                    tags$li(tags$strong("Niska:"), " Koristimo globalni prosek")
                  ),
                  
                  tags$h5("🎯 Korekcija za veličinu:"),
                  tags$ul(
                    tags$li("Stanovi < 50m²: ", tags$strong("+5%"), " (veća cena po m²)"),
                    tags$li("Stanovi 50-100m²: ", tags$strong("Bez korekcije")),
                    tags$li("Stanovi > 100m²: ", tags$strong("-5%"), " (niža cena po m²)")
                  ),
                  
                  tags$hr(),
                  
                  tags$h5("💡 Napomena:"),
                  tags$p(
                    "Realna cena zavisi od mnogih faktora: stanje objekta, sprat, ",
                    "orijentacija, parking, lift, itd. Ova procena je samo okvirna!"
                  )
                )
              )
      ),
      
      # TAB 5: Agregirani Prikaz
      tabItem(tabName = "tabela",
              fluidRow(
                box(title = "Agregirani Prikaz po Lokaciji", status = "primary", solidHeader = TRUE, width = 12, 
                    DTOutput("tabela_agregirano"))
              )
      )
    )
  )
)

# ==============================================================================
# --- 4. SERVER ---
# ==============================================================================
# ==============================================================================
# --- 4. SERVER ---
# ==============================================================================
server <- function(input, output, session) {
  
  # ===========================================================================
  # DEBOUNCE REAKTIVNIH INPUTA
  # ===========================================================================
  
  filter_cena_min_debounced <- debounce(reactive(input$filter_cena_min), 1000)
  filter_cena_max_debounced <- debounce(reactive(input$filter_cena_max), 1000)
  filter_kvadratura_min_debounced <- debounce(reactive(input$filter_kvadratura_min), 1000)
  filter_kvadratura_max_debounced <- debounce(reactive(input$filter_kvadratura_max), 1000)
  
  # ===========================================================================
  # VALIDACIJA INPUTA
  # ===========================================================================
  
  observe({
    if (!is.na(filter_cena_max_debounced()) && !is.na(filter_cena_min_debounced())) {
      if (filter_cena_max_debounced() < filter_cena_min_debounced()) {
        showNotification("⚠️ Max cena ne može biti manja od Min cene!", 
                         type = "warning", duration = 3)
      }
    }
    
    if (!is.na(filter_kvadratura_max_debounced()) && !is.na(filter_kvadratura_min_debounced())) {
      if (filter_kvadratura_max_debounced() < filter_kvadratura_min_debounced()) {
        showNotification("⚠️ Max kvadratura ne može biti manja od Min kvadrature!", 
                         type = "warning", duration = 3)
      }
    }
  })
  
  # ===========================================================================
  # FILTRIRANJE PODATAKA
  # ===========================================================================
  
  filtered_data <- reactive({
    df <- all_data
    
    if (!is.null(input$filter_izvor) && !("Svi" %in% input$filter_izvor)) {
      df <- df %>% filter(Izvor %in% input$filter_izvor)
    }
    
    if (!is.null(input$filter_grad) && !("Svi" %in% input$filter_grad)) {
      df <- df %>% filter(Grad %in% input$filter_grad)
    }
    
    cena_min <- ifelse(is.na(filter_cena_min_debounced()), 5000, filter_cena_min_debounced())
    cena_max <- ifelse(is.na(filter_cena_max_debounced()), 1000000, filter_cena_max_debounced())
    
    if (cena_min > cena_max) {
      cena_min <- 5000
      cena_max <- 1000000
    }
    
    df <- df %>%
      filter(Cena >= cena_min & Cena <= cena_max)
    
    kv_min <- ifelse(is.na(filter_kvadratura_min_debounced()), 10, filter_kvadratura_min_debounced())
    kv_max <- ifelse(is.na(filter_kvadratura_max_debounced()), 500, filter_kvadratura_max_debounced())
    
    if (kv_min > kv_max) {
      kv_min <- 10
      kv_max <- 500
    }
    
    df <- df %>%
      filter(Kvadratura >= kv_min & Kvadratura <= kv_max)
    
    return(df)
  })
  
  # ===========================================================================
  # DYNAMIC FILTER UPDATE
  # ===========================================================================
  
  observe({
    dostupni_gradovi <- all_data
    if (!is.null(input$filter_izvor) && !("Svi" %in% input$filter_izvor)) {
      dostupni_gradovi <- dostupni_gradovi %>% filter(Izvor %in% input$filter_izvor)
    }
    lista_gradova <- sort(unique(dostupni_gradovi$Grad))
    updateSelectInput(session, "filter_grad", choices = c("Svi", lista_gradova), selected = input$filter_grad)
  })
  
  # ===========================================================================
  # RESETOVANJE FILTERA (DODAJ OVO - bilo je nedostajalo!)
  # ===========================================================================
  
  observeEvent(input$reset_filters, {
    updateSelectInput(session, "filter_izvor", selected = "Svi")
    updateSelectInput(session, "filter_grad", selected = "Svi")
    updateNumericInput(session, "filter_cena_min", value = 5000)
    updateNumericInput(session, "filter_cena_max", value = 500000)
    updateNumericInput(session, "filter_kvadratura_min", value = 10)
    updateNumericInput(session, "filter_kvadratura_max", value = 300)
    
    showNotification("✅ Filteri su uspešno resetovani!", type = "message", duration = 3)
  })
  

  
  # ===========================================================================
  # TAB 1: PREGLED - Value Boxes
  # ===========================================================================
  
  output$box_ukupno_oglasa <- renderValueBox({ 
    valueBox(
      value = format(nrow(filtered_data()), big.mark = "."), 
      subtitle = "Ukupno Oglasa", 
      icon = icon("home"), 
      color = "blue"
    ) 
  })
  
  output$box_medijan_cena <- renderValueBox({
    median_price <- median(filtered_data()$Cena, na.rm = TRUE)
    valueBox(
      value = paste(format(round(median_price), big.mark = "."), "€"), 
      subtitle = "Medijan Cena", 
      icon = icon("euro-sign"), 
      color = "yellow"
    )
  })
  
  output$box_medijan_kvadratura <- renderValueBox({
    median_m2 <- median(filtered_data()$Kvadratura, na.rm = TRUE)
    valueBox(
      value = paste(round(median_m2, 1), "m²"), 
      subtitle = "Medijan Kvadratura", 
      icon = icon("ruler-combined"), 
      color = "purple"
    )
  })
  
  output$box_medijan_cena_po_m2 <- renderValueBox({
    median_price_m2 <- median(filtered_data()$Cena_po_m2, na.rm = TRUE)
    valueBox(
      value = paste(format(round(median_price_m2), big.mark = "."), "€/m²"), 
      subtitle = "Medijan Cena po m²", 
      icon = icon("tag"), 
      color = "green"
    )
  })
  
  output$plot_izvor <- renderPlotly({ 
    req(nrow(filtered_data()) > 0)
    df <- filtered_data() %>% 
      count(Izvor, name = "Broj_Oglasa") %>% 
      arrange(desc(Broj_Oglasa))
    plot_ly(df, labels = ~Izvor, values = ~Broj_Oglasa, type = 'pie', textinfo = 'label+percent') %>% 
      layout(showlegend = TRUE) 
  })
  
  output$plot_grad_top10 <- renderPlotly({ 
    req(nrow(filtered_data()) > 0)
    df <- filtered_data() %>% 
      count(Grad, name = "Broj_Oglasa") %>% 
      top_n(10, Broj_Oglasa)
    plot_ly(df, x = ~Broj_Oglasa, y = ~reorder(Grad, Broj_Oglasa), type = 'bar', orientation = 'h') %>% 
      layout(yaxis = list(title = ""), xaxis = list(title = "Broj Oglasa")) 
  })
  
  # ===========================================================================
  # TAB 2: ANALIZA GRADOVA
  # ===========================================================================
  
  output$plot_grad_cena_m2 <- renderPlotly({
    req(nrow(filtered_data()) > 0)
    df <- filtered_data() %>%
      group_by(Grad) %>%
      summarise(Median_Cena_m2 = median(Cena_po_m2, na.rm = TRUE), Broj_Oglasa = n(), .groups = "drop") %>%
      filter(Broj_Oglasa >= 10) %>% 
      top_n(15, Median_Cena_m2)
    plot_ly(df, x = ~Median_Cena_m2, y = ~reorder(Grad, Median_Cena_m2), type = 'bar', orientation = 'h') %>%
      layout(yaxis = list(title = ""), xaxis = list(title = "Medijan Cena po m² (€)"))
  })
  
  # ===========================================================================
  # TAB 3: ANALIZA KVADRATURA - SERVER (ISPRAVLJENO)
  # ===========================================================================
  
  # 1. INICIJALIZACIJA - Popuni dropdown sa gradovima pri pokretanju
  observe({
    # Samo gradovi sa dovoljno podataka
    top_gradovi <- all_data %>% 
      count(Grad, name = "Broj") %>%
      filter(Broj >= 20) %>%
      arrange(desc(Broj)) %>%
      head(20) %>%
      pull(Grad)
    
    updateSelectInput(session, "kvadratura_gradovi", 
                      choices = top_gradovi,
                      selected = character(0))  # Prazan početni izbor
  })
  
  # 2. GLAVNI GRAFIK - Sve kategorije (OSTAJE ISTO)
  output$plot_kvadratura_grupe <- renderPlotly({
    req(nrow(filtered_data()) > 0)
    
    kategorije_kvadrature <- c("0-30 m²", "31-50 m²", "51-70 m²", "71-90 m²", "91-120 m²", "> 120 m²")
    
    df <- filtered_data() %>%
      mutate(Kategorija_m2 = case_when(
        Kvadratura <= 30 ~ kategorije_kvadrature[1],
        Kvadratura <= 50 ~ kategorije_kvadrature[2],
        Kvadratura <= 70 ~ kategorije_kvadrature[3],
        Kvadratura <= 90 ~ kategorije_kvadrature[4],
        Kvadratura <= 120 ~ kategorije_kvadrature[5],
        TRUE ~ kategorije_kvadrature[6]
      ) %>% factor(levels = kategorije_kvadrature)) %>%
      group_by(Kategorija_m2) %>%
      summarise(
        Median_Cena_m2 = median(Cena_po_m2, na.rm = TRUE),
        Broj_Oglasa = n(),
        .groups = "drop"
      ) %>%
      filter(Broj_Oglasa >= 10)
    
    plot_ly(df, x = ~Kategorija_m2, y = ~Median_Cena_m2, type = 'bar',
            marker = list(color = 'rgba(100, 150, 250, 0.8)'),
            text = ~paste(round(Median_Cena_m2), "€/m²<br>", Broj_Oglasa, "oglasa"), 
            textposition = 'outside',
            hoverinfo = "text") %>%
      layout(
        xaxis = list(title = "Kategorija Kvadrature"),
        yaxis = list(title = "Medijan Cena po m² (€)")
      )
  })
  
  # 3. DINAMIČKI UI ZA GRAFIKE PO GRADOVIMA
  output$plot_kvadratura_po_gradu_ui <- renderUI({
    # Provera da li su gradovi izabrani
    if (is.null(input$kvadratura_gradovi) || length(input$kvadratura_gradovi) == 0) {
      return(
        box(
          width = 12,
          status = "warning",
          h4("📍 Izaberite gradove iz padajućeg menija za detaljnu analizu")
        )
      )
    }
    
    izabrani_gradovi <- input$kvadratura_gradovi
    
    # Limitiraj na 4 grada
    if (length(izabrani_gradovi) > 4) {
      izabrani_gradovi <- izabrani_gradovi[1:4]
      showNotification(
        "⚠️ Prikazujemo samo prvih 4 grada za bolju preglednost",
        type = "warning",
        duration = 3
      )
    }
    
    # Kreiraj box za svaki grad
    plot_boxes <- lapply(seq_along(izabrani_gradovi), function(i) {
      grad <- izabrani_gradovi[i]
      box(
        title = paste("📊", grad),
        status = "primary",
        solidHeader = TRUE,
        width = if(length(izabrani_gradovi) == 1) 12 else 6,
        plotlyOutput(paste0("plot_grad_kvadratura_", i), height = "350px")
      )
    })
    
    do.call(fluidRow, plot_boxes)
  })
  
  # 4. GENERISANJE GRAFIKA ZA SVAKI GRAD
  observe({
    # Provera da li su gradovi izabrani
    if (is.null(input$kvadratura_gradovi) || length(input$kvadratura_gradovi) == 0) {
      return()
    }
    
    izabrani_gradovi <- input$kvadratura_gradovi
    if (length(izabrani_gradovi) > 4) {
      izabrani_gradovi <- izabrani_gradovi[1:4]
    }
    
    kategorije_kvadrature <- c("0-30 m²", "31-50 m²", "51-70 m²", "71-90 m²", "91-120 m²", "> 120 m²")
    
    lapply(seq_along(izabrani_gradovi), function(i) {
      grad <- izabrani_gradovi[i]
      output_name <- paste0("plot_grad_kvadratura_", i)
      
      output[[output_name]] <- renderPlotly({
        df_grad <- filtered_data() %>%
          filter(Grad == grad) %>%
          mutate(Kategorija_m2 = case_when(
            Kvadratura <= 30 ~ kategorije_kvadrature[1],
            Kvadratura <= 50 ~ kategorije_kvadrature[2],
            Kvadratura <= 70 ~ kategorije_kvadrature[3],
            Kvadratura <= 90 ~ kategorije_kvadrature[4],
            Kvadratura <= 120 ~ kategorije_kvadrature[5],
            TRUE ~ kategorije_kvadrature[6]
          ) %>% factor(levels = kategorije_kvadrature)) %>%
          group_by(Kategorija_m2) %>%
          summarise(
            Median_Cena_m2 = median(Cena_po_m2, na.rm = TRUE),
            Broj_Oglasa = n(),
            .groups = "drop"
          ) %>%
          filter(Broj_Oglasa >= 3)
        
        if (nrow(df_grad) == 0) {
          return(
            plotly_empty() %>%
              layout(title = list(text = "Nema dovoljno podataka", x = 0.5))
          )
        }
        
        colors <- c("#3498db", "#e74c3c", "#2ecc71", "#f39c12")
        color <- colors[((i - 1) %% 4) + 1]
        
        plot_ly(df_grad, 
                x = ~Kategorija_m2, 
                y = ~Median_Cena_m2, 
                type = 'bar',
                marker = list(color = color),
                text = ~paste(round(Median_Cena_m2), "€/m²<br>", Broj_Oglasa, "oglasa"),
                textposition = 'outside',
                hoverinfo = "text") %>%
          layout(
            xaxis = list(title = "Kategorija", tickangle = -45),
            yaxis = list(title = "€/m²"),
            margin = list(b = 80)
          )
      })
    })
  })
  
  # ===========================================================================
  # TAB 4: STATISTIČKA ANALIZA
  # ===========================================================================
  
  # --- Value Boxes: Percentili i Korelacija ---
  
  output$box_percentil_25 <- renderValueBox({
    p25 <- quantile(filtered_data()$Cena_po_m2, 0.25, na.rm = TRUE)
    valueBox(
      value = paste(format(round(p25), big.mark = "."), "€/m²"),
      subtitle = "25. Percentil",
      icon = icon("chart-line"),
      color = "light-blue"
    )
  })
  
  output$box_percentil_50 <- renderValueBox({
    p50 <- median(filtered_data()$Cena_po_m2, na.rm = TRUE)
    valueBox(
      value = paste(format(round(p50), big.mark = "."), "€/m²"),
      subtitle = "50. Percentil (Medijan)",
      icon = icon("chart-line"),
      color = "blue"
    )
  })
  
  output$box_percentil_75 <- renderValueBox({
    p75 <- quantile(filtered_data()$Cena_po_m2, 0.75, na.rm = TRUE)
    valueBox(
      value = paste(format(round(p75), big.mark = "."), "€/m²"),
      subtitle = "75. Percentil",
      icon = icon("chart-line"),
      color = "navy"
    )
  })
  
  output$box_korelacija <- renderValueBox({
    cor_val <- cor(filtered_data()$Kvadratura, filtered_data()$Cena, use = "complete.obs")
    valueBox(
      value = round(cor_val, 3),
      subtitle = "Korelacija (Kvadratura-Cena)",
      icon = icon("link"),
      color = if(abs(cor_val) > 0.7) "green" else if(abs(cor_val) > 0.4) "yellow" else "red"
    )
  })
  
  # --- Histogram: Distribucija cena po m² ---
  
  output$plot_histogram <- renderPlotly({
    req(nrow(filtered_data()) > 0)
    
    df <- filtered_data()
    median_val <- median(df$Cena_po_m2, na.rm = TRUE)
    
    plot_ly(df, x = ~Cena_po_m2, type = "histogram", nbinsx = 50,
            marker = list(color = 'rgba(100, 150, 250, 0.7)',
                          line = list(color = 'rgba(100, 150, 250, 1)', width = 1))) %>%
      add_segments(x = median_val, xend = median_val, 
                   y = 0, yend = max(table(cut(df$Cena_po_m2, breaks = 50))),
                   line = list(color = 'red', width = 2, dash = 'dash'),
                   name = paste("Medijan:", format(round(median_val), big.mark = "."), "€/m²")) %>%
      layout(
        xaxis = list(title = "Cena po m² (€)"),
        yaxis = list(title = "Broj Oglasa"),
        showlegend = TRUE
      )
  })
  
  # --- Box Plot: Distribucija po gradovima ---
  
  output$plot_boxplot <- renderPlotly({
    req(nrow(filtered_data()) > 0)
    
    top_gradovi <- filtered_data() %>%
      count(Grad, name = "Broj") %>%
      top_n(10, Broj) %>%
      pull(Grad)
    
    df <- filtered_data() %>%
      filter(Grad %in% top_gradovi)
    
    plot_ly(df, y = ~Cena_po_m2, x = ~Grad, type = "box",
            marker = list(color = 'rgba(100, 150, 250, 0.7)')) %>%
      layout(
        xaxis = list(title = ""),
        yaxis = list(title = "Cena po m² (€)")
      )
  })
  
  # --- Scatter Plot: Korelacija Kvadratura vs Cena ---
  
  output$plot_scatter <- renderPlotly({
    req(nrow(filtered_data()) > 0)
    
    df <- filtered_data() %>%
      sample_n(min(5000, nrow(filtered_data()))) # Limitiramo na 5000 tačaka za performanse
    
    plot_ly(df, x = ~Kvadratura, y = ~Cena, type = "scatter", mode = "markers",
            color = ~Grad, 
            marker = list(size = 5, opacity = 0.6),
            text = ~paste("Grad:", Grad, "<br>Kvadratura:", Kvadratura, "m²<br>Cena:", format(Cena, big.mark = "."), "€"),
            hoverinfo = "text") %>%
      add_lines(x = ~Kvadratura, y = fitted(lm(Cena ~ Kvadratura, data = df)),
                line = list(color = 'red', width = 2),
                name = "Regresiona linija",
                showlegend = TRUE) %>%
      layout(
        xaxis = list(title = "Kvadratura (m²)"),
        yaxis = list(title = "Cena (€)"),
        showlegend = TRUE
      )
  })
  
  # --- Tabele: Outliers (Jeftine i Skupe) ---
  
  output$tabela_jeftine <- renderDT({
    req(nrow(filtered_data()) > 0)
    
    p5 <- quantile(filtered_data()$Cena_po_m2, 0.05, na.rm = TRUE)
    
    jeftine <- filtered_data() %>%
      filter(Cena_po_m2 <= p5) %>%
      select(Grad, Lokacija, Cena, Kvadratura, Cena_po_m2, Link) %>%
      arrange(Cena_po_m2) %>%
      head(50)
    
    datatable(jeftine,
              rownames = FALSE,
              options = list(pageLength = 10, scrollX = TRUE),
              escape = FALSE) %>%
      formatCurrency(c("Cena", "Cena_po_m2"), currency = "€", interval = 3, mark = ".", digits = 0)
  })
  
  output$tabela_skupe <- renderDT({
    req(nrow(filtered_data()) > 0)
    
    p95 <- quantile(filtered_data()$Cena_po_m2, 0.95, na.rm = TRUE)
    
    skupe <- filtered_data() %>%
      filter(Cena_po_m2 >= p95) %>%
      select(Grad, Lokacija, Cena, Kvadratura, Cena_po_m2, Link) %>%
      arrange(desc(Cena_po_m2)) %>%
      head(50)
    
    datatable(skupe,
              rownames = FALSE,
              options = list(pageLength = 10, scrollX = TRUE),
              escape = FALSE) %>%
      formatCurrency(c("Cena", "Cena_po_m2"), currency = "€", interval = 3, mark = ".", digits = 0)
  })
  
  # ===========================================================================
  # TAB 5: AGREGIRANI PRIKAZ
  # ===========================================================================
  
  output$tabela_agregirano <- renderDT({
    lokacije_summary <- filtered_data() %>%
      filter(!is.na(Lokacija)) %>%
      group_by(Grad, Lokacija) %>%
      summarise(
        Broj_Oglasa = n(),
        Medijan_Cena = round(median(Cena, na.rm = TRUE)),
        Medijan_Kvadratura = round(median(Kvadratura, na.rm = TRUE), 1),
        Medijan_Cena_po_m2 = round(median(Cena_po_m2, na.rm = TRUE)),
        Min_Cena_po_m2 = round(min(Cena_po_m2, na.rm = TRUE)),
        Max_Cena_po_m2 = round(max(Cena_po_m2, na.rm = TRUE)),
        .groups = "drop"
      ) %>%
      arrange(desc(Broj_Oglasa))
    
    datatable(lokacije_summary,
              rownames = FALSE,
              options = list(pageLength = 15, scrollX = TRUE)) %>%
      formatCurrency(c("Medijan_Cena", "Medijan_Cena_po_m2", "Min_Cena_po_m2", "Max_Cena_po_m2"), 
                     currency = "€", interval = 3, mark = ".", digits = 0)
  })
  
  
  # ===========================================================================
  # TAB 6: KALKULATOR CENE (NOVO!)
  # ===========================================================================
  
  # Dinamički dropdown za lokaciju
  output$calc_lokacija_ui <- renderUI({
    req(input$calc_grad)
    
    if (input$calc_grad == "") {
      return(NULL)
    }
    
    lokacije <- all_data %>%
      filter(Grad == input$calc_grad, !is.na(Lokacija), Lokacija != "") %>%
      pull(Lokacija) %>%
      unique() %>%
      sort()
    
    selectInput("calc_lokacija", "Izaberite lokaciju (opciono):",
                choices = c("Sve" = "Sve", lokacije),
                selected = "Sve")
  })
  
  # Reactive vrednosti za predviđanje
  prediction_values <- eventReactive(input$calc_predict, {
    req(input$calc_grad, input$calc_kvadratura)
    
    if (input$calc_grad == "") {
      showNotification("⚠️ Molimo izaberite grad!", type = "warning", duration = 3)
      return(NULL)
    }
    
    lokacija_input <- if(is.null(input$calc_lokacija) || input$calc_lokacija == "Sve") {
      NULL
    } else {
      input$calc_lokacija
    }
    
    result <- predict_price_per_m2(
      grad = input$calc_grad,
      lokacija = lokacija_input,
      kvadratura = input$calc_kvadratura
    )
    
    result$total_price <- result$predicted_price_m2 * input$calc_kvadratura
    result$total_lower <- result$lower_bound * input$calc_kvadratura
    result$total_upper <- result$upper_bound * input$calc_kvadratura
    result$kvadratura <- input$calc_kvadratura
    result$grad <- input$calc_grad
    result$lokacija <- lokacija_input
    
    return(result)
  })
  
  # Prikaz rezultata
  output$prediction_results <- renderUI({
    pred <- prediction_values()
    req(pred)
    
    confidence_color <- switch(pred$confidence,
                               "Visoka" = "success",
                               "Srednja" = "warning",
                               "Niska" = "danger")
    
    tagList(
      h4("📊 Rezultati:", style = "margin-top: 20px;"),
      
      tags$div(
        style = "background-color: #f4f4f4; padding: 15px; border-radius: 5px; margin-bottom: 10px;",
        tags$strong("Cena po m²:"),
        tags$h3(
          paste(format(pred$predicted_price_m2, big.mark = "."), "€/m²"),
          style = "color: #00a65a; margin: 5px 0;"
        ),
        tags$small(
          paste("Raspon:", format(pred$lower_bound, big.mark = "."), "-", 
                format(pred$upper_bound, big.mark = "."), "€/m²")
        )
      ),
      
      tags$div(
        style = "background-color: #e3f2fd; padding: 15px; border-radius: 5px; margin-bottom: 10px;",
        tags$strong("Ukupna cena:"),
        tags$h3(
          paste(format(pred$total_price, big.mark = "."), "€"),
          style = "color: #0073e6; margin: 5px 0;"
        ),
        tags$small(
          paste("Raspon:", format(pred$total_lower, big.mark = "."), "-", 
                format(pred$total_upper, big.mark = "."), "€")
        )
      ),
      
      tags$div(
        class = paste0("alert alert-", confidence_color),
        style = "margin-bottom: 10px;",
        tags$strong("Pouzdanost: "), pred$confidence,
        tags$br(),
        tags$small(paste("Bazirana na", pred$n_samples, "oglasa")),
        tags$br(),
        tags$small(paste("Izvor:", pred$source))
      )
    )
  })
}

# ==============================================================================
# --- 5. Pokretanje aplikacije ---
# ==============================================================================
shinyApp(ui, server)