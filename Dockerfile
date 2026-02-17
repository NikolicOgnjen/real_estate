# Koristimo zvanični lagani Python 3.11 image
FROM python:3.11-slim

# Postavljamo radni direktorijum unutar kontejnera
WORKDIR /app

# Kopiramo requirements.txt i instaliramo zavisnosti
# Radimo ovo pre kopiranja koda da iskoristimo Docker layer cache
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Kopiramo Python skripte
COPY scrapers/ ./scrapers/

# Podrazumevana komanda (override-uje se u docker-compose.yml)
CMD ["python", "--version"]