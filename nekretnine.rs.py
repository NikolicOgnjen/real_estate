import asyncio
import aiohttp
from bs4 import BeautifulSoup
from datetime import datetime
import time
import sqlite3
import re

# --- PODEŠAVANJA ---
DB_NAME = "nekretnine.rs_data.db"
BATCH_SIZE = 100  # Koliko stranica obrađivati odjednom
MAX_CONCURRENT_REQUESTS = 5
RETRY_COUNT = 3
RETRY_DELAY = 5
# --- KRAJ PODEŠAVANJA ---

# Cenovni opsezi za pretragu
PRICE_RANGES = [
    (0, 50000),
    (50000, 75000),
    (75000, 100000),
    (100000, 125000),
    (125000, 150000),
    (150000, 175000),
    (175000, 200000),
    (200000, 225000),
    (225000, 250000),
    (250000, 275000),
    (275000, 300000),
    (300000, 325000),
    (325000, 350000),
    (350000, 375000),
    (375000, 400000),
    (400000, 425000),
    (425000, 450000),
    (450000, 475000),
    (475000, 500000),
    (500000, 9999999)  # Sve ostalo
]

BASE_URL = "https://www.nekretnine.rs/stambeni-objekti/izdavanje-prodaja/prodaja/cena/{min_price}_{max_price}/lista/po-stranici/20/stranica/{page}/"
HEADERS = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36'
}


def init_database():
    """Kreira SQLite bazu i tabelu 'oglasi' ako ne postoje."""
    conn = sqlite3.connect(DB_NAME)
    cursor = conn.cursor()
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS oglasi (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            Naslov TEXT,
            Cena TEXT,
            Cena_po_m2 TEXT,
            Lokacija TEXT,
            Kvadratura TEXT,
            Tip_stana TEXT,
            Datum_oglasa TEXT,
            URL TEXT,
            Datum_preuzimanja TEXT
        )
    ''')
    conn.commit()
    conn.close()
    print(f"✔️  Baza podataka '{DB_NAME}' je spremna.")


def save_to_database(data_list):
    """Čuva SVE oglase u bazu, bez provere duplikata."""
    if not data_list:
        return 0

    conn = sqlite3.connect(DB_NAME)
    cursor = conn.cursor()

    insert_query = '''
        INSERT INTO oglasi (Naslov, Cena, Cena_po_m2, Lokacija, Kvadratura, Tip_stana, Datum_oglasa, URL, Datum_preuzimanja)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    '''

    data_to_insert = [
        (
            oglas['Naslov'], oglas['Cena'], oglas['Cena_po_m2'], oglas['Lokacija'],
            oglas['Kvadratura'], oglas['Tip_stana'], oglas['Datum_oglasa'], oglas['URL'],
            datetime.now().date().isoformat()
        )
        for oglas in data_list
    ]

    cursor.executemany(insert_query, data_to_insert)
    conn.commit()
    conn.close()
    return len(data_list)


def parse_html_page(html_content):
    soup = BeautifulSoup(html_content, 'lxml')
    oglasi = soup.find_all('div', class_='row offer')
    if not oglasi:
        return []  # Nema oglasa = kraj stranica
    page_data = []

    for oglas in oglasi:
        try:
            # URL oglasa (NAJVAŽNIJE!)
            url_tag = oglas.find('a', href=re.compile(r'/stambeni-objekti/'))
            url = "https://www.nekretnine.rs" + url_tag['href'] if url_tag else 'N/A'
            # Naslov
            naslov_tag = oglas.find('h2', class_='offer-title')
            naslov = naslov_tag.text.strip() if naslov_tag else 'N/A'
            # Cena
            cena_tag = oglas.find('p', class_='offer-price')
            cena = 'N/A'
            if cena_tag:
                cena_span = cena_tag.find('span')
                if cena_span:
                    cena = cena_span.text.strip()
            # Cena po m²
            cena_po_m2 = 'N/A'
            if cena_tag:
                cena_m2_tag = cena_tag.find('small', class_='custom-offer-style')
                if cena_m2_tag:
                    cena_po_m2 = cena_m2_tag.text.strip()
            # Lokacija
            lokacija_tag = oglas.find('p', class_='offer-location')
            lokacija = lokacija_tag.text.strip() if lokacija_tag else 'N/A'
            # Kvadratura
            kvadratura = 'N/A'
            kvadratura_tags = oglas.find_all('p', class_='offer-price')
            for tag in kvadratura_tags:
                if 'offer-price--invert' in tag.get('class', []):
                    span = tag.find('span')
                    if span and 'm²' in span.text:
                        kvadratura = span.text.strip()
                        break

            # Meta info (Datum i Tip stana)
            meta_info_tag = oglas.find('div', class_='offer-meta-info')
            datum_oglasa = 'N/A'
            tip_stana = 'N/A'

            if meta_info_tag:
                meta_text = meta_info_tag.text.strip()
                parts = [p.strip() for p in meta_text.split('|')]
                if len(parts) >= 1:
                    datum_oglasa = parts[0].strip()
                if len(parts) >= 3:
                    tip_stana = parts[2].strip()

            podaci_oglasa = {
                "Naslov": naslov,
                "Cena": cena,
                "Cena_po_m2": cena_po_m2,
                "Lokacija": lokacija,
                "Kvadratura": kvadratura,
                "Tip_stana": tip_stana,
                "Datum_oglasa": datum_oglasa,
                "URL": url
            }

            page_data.append(podaci_oglasa)

        except Exception as e:
            print(f"   ⚠️  Greška pri parsiranju oglasa: {e}")
            continue

    return page_data


async def fetch_page(session, url, semaphore):
    """Asinhrono preuzima stranicu sa retry logikom."""
    for attempt in range(RETRY_COUNT):
        async with semaphore:
            if attempt > 0:
                print(f"   -> Ponovni pokušaj ({attempt + 1}/{RETRY_COUNT}) za {url}")
            try:
                async with session.get(url, timeout=25) as response:
                    if response.status == 200:
                        return await response.text()
                    else:
                        print(f"   ❌ Greška za {url}, Status: {response.status}. Pokušaj {attempt + 1}.")
            except (aiohttp.ClientError, asyncio.TimeoutError) as e:
                print(f"   🔥 Greška konekcije za {url} (pokušaj {attempt + 1}): {type(e).__name__}")

        if attempt < RETRY_COUNT - 1:
            await asyncio.sleep(RETRY_DELAY)

    print(f"   💀 Odustajem od {url} nakon {RETRY_COUNT} pokušaja.")
    return None


async def process_price_range(session, semaphore, min_price, max_price):
    """Obrađuje jedan cenovni opseg, stranica po stranica, sve dok ima oglasa."""
    print(f"\n{'=' * 60}")
    print(f"💰 Počinjem obradu cenovnog opsega: {min_price:,} - {max_price:,} €")
    print(f"{'=' * 60}")

    total_ads_in_range = 0
    page = 1

    while True:
        print(f"\n--- Stranica {page} (Cena: {min_price:,}-{max_price:,} €) ---")

        url = BASE_URL.format(min_price=min_price, max_price=max_price, page=page)
        html = await fetch_page(session, url, semaphore)

        if not html:
            print(f"   ⚠️  Nije moguće preuzeti stranicu {page}. Zaustavljam ovaj opseg.")
            break

        ads_data = parse_html_page(html)

        if not ads_data:
            print(f"   🛑 Nema oglasa na stranici {page}. Zaustavljam ovaj cenovni opseg.")
            break

        print(f"   ✅ Pronađeno {len(ads_data)} oglasa na stranici {page}.")
        added_count = save_to_database(ads_data)
        total_ads_in_range += added_count
        print(f"   💾 Sačuvano {added_count} oglasa u bazu.")

        page += 1

        # Kratka pauza između stranica da ne opteretimo server
        await asyncio.sleep(0.5)

    print(f"\n✅ Završeno za opseg {min_price:,}-{max_price:,} €. Ukupno: {total_ads_in_range} oglasa.")
    return total_ads_in_range


async def main():
    start_time = time.time()
    init_database()

    print(f"🚀 Započinjem scraping sa nekretnine.rs")
    print(f"📊 Broj cenovnih opsega: {len(PRICE_RANGES)}")

    semaphore = asyncio.Semaphore(MAX_CONCURRENT_REQUESTS)
    total_ads_all_ranges = 0

    async with aiohttp.ClientSession(headers=HEADERS) as session:
        for min_price, max_price in PRICE_RANGES:
            ads_count = await process_price_range(session, semaphore, min_price, max_price)
            total_ads_all_ranges += ads_count

    print("\n" + "=" * 60)
    print("🏁 ZAVRŠENO PREUZIMANJE SVIH CENOVNIH OPSEGA 🏁")
    print("=" * 60)

    print(f"\n🗃️  Ukupno dodato oglasa u bazu: {total_ads_all_ranges}")

    end_time = time.time()
    print(f"⏱️  Ukupno vreme izvršavanja: {end_time - start_time:.2f} sekundi.")


if __name__ == "__main__":
    asyncio.run(main())