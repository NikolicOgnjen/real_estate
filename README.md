# 🏠 Real Estate Serbia — Data Engineering Pipeline

End-to-end data engineering project that collects, stores, and visualizes real estate listings from Serbian property portals (nekretnine.rs and oglasi.rs).

## 🏗️ Architecture

```
┌─────────────────┐    ┌─────────────────┐
│  nekretnine.rs  │    │   oglasi.rs     │
│  (async scraper)│    │ (async scraper) │
└────────┬────────┘    └────────┬────────┘
         │                      │
         └──────────┬───────────┘
                    │
                    ▼
         ┌─────────────────────┐
         │   PostgreSQL (RDS)  │
         │   Docker container  │
         └──────────┬──────────┘
                    │
                    ▼
         ┌─────────────────────┐
         │   R Shiny Dashboard │
         │   (Analytics & viz) │
         └─────────────────────┘
```

## 🛠️ Tech Stack

| Layer | Technology |
|-------|-----------|
| Scraping | Python, asyncio, aiohttp, BeautifulSoup |
| Database | PostgreSQL 15 |
| Orchestration | Apache Airflow *(coming — Faza 3)* |
| Containerization | Docker, Docker Compose |
| CI/CD | GitHub Actions *(coming — Faza 2)* |
| Cloud | AWS EC2 + RDS *(coming — Faza 4)* |
| Visualization | R Shiny |

## 📦 Pokretanje lokalno

### Preduslovi
- Docker Desktop instaliran
- Git

### 1. Kloniraj repozitorijum
```bash
git clone https://github.com/TVOJ_USERNAME/real-estate-serbia.git
cd real-estate-serbia
```

### 2. Pokreni PostgreSQL
```bash
docker compose up postgres -d
```

### 3. Pokreni scrapere
```bash
# Oba scrapera paralelno
docker compose up

# Ili samo jedan
docker compose run nekretnine-scraper
docker compose run oglasi-scraper
```

### 4. Proveri podatke
```bash
# Poveži se na PostgreSQL
docker exec -it real_estate_db psql -U postgres -d real_estate

# Broj oglasa po izvoru
SELECT izvor, COUNT(*) FROM v_all_listings GROUP BY izvor;
```

## 📁 Struktura projekta

```
real-estate-serbia/
├── scrapers/
│   ├── nekretnine_scraper.py   # Scraper za nekretnine.rs (async)
│   └── oglasi_scraper.py       # Scraper za oglasi.rs (async)
├── sql/
│   └── init.sql                # PostgreSQL schema i view-ovi
├── dashboards/
│   └── app.R                   # R Shiny aplikacija
├── .github/
│   └── workflows/              # GitHub Actions (CI/CD) — WIP
├── Dockerfile
├── docker-compose.yml
├── requirements.txt
└── README.md
```

## 🗺️ Roadmap

- [x] **Faza 1** — Docker + PostgreSQL + GitHub
- [ ] **Faza 2** — GitHub Actions (CI/CD)
- [ ] **Faza 3** — Apache Airflow (scheduled pipeline)
- [ ] **Faza 4** — AWS deployment (EC2 + RDS)

## 📊 Dashboard

Shiny aplikacija pruža:
- Pregled tržišta (broj oglasa, medijan cena)
- Analizu po gradovima i kvadraturi
- Statističku analizu (percentili, distribucija, outlieri)
- Kalkulator fer cene nekretnine

---

*Projekat u aktivnom razvoju — portfolio projekat za Data Engineering.*
