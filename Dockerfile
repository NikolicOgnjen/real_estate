# 1. Koristi zvanični lagani Python image
FROM python:3.11-slim

# 2. Postavi radni direktorijum unutar kontejnera
WORKDIR /app

# 3. Kopiraj listu biblioteka i instaliraj ih
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY nekretnine_scraper.py .
COPY oglasi_scraper.py .

# 5. Ovde ne stavljamo CMD jer imamo dve skripte, 
# definisaćemo ih u docker-compose fajlu.
