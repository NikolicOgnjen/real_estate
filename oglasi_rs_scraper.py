import asyncio
import aiohttp
from bs4 import BeautifulSoup
from datetime import datetime
import time
import sqlite3

# --- PODESAVANJA ---
DB_NAME = "oglasi.rs_data.db"
START_PAGE = 1
END_PAGE = 1800  # Spremni za punu ekstrakciju
BATCH_SIZE = 100  # NOVO: Koliko stranica obrađivati odjednom
MAX_CONCURRENT_REQUESTS = 5
RETRY_COUNT = 3
RETRY_DELAY = 5
# --- KRAJ PODESAVANJA ---

BASE_URL = "https://www.oglasi.rs/nekretnine/prodaja-stanova?p={}"
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
            Grad TEXT,
            Lokacija TEXT,
            Kvadratura TEXT,
            Sobnost TEXT,
            Sprat TEXT,
            Link TEXT,
            Datum_preuzimanja TEXT
        )
    ''')
    conn.commit()
    conn.close()
    print(f"✔️  Baza podataka '{DB_NAME}' je spremna (dozvoljeni duplikati, sa kolonom 'Grad').")


def save_to_database(data_list):
    """Čuva SVE oglase u bazu, bez provere duplikata."""
    if not data_list:
        return 0

    conn = sqlite3.connect(DB_NAME)
    cursor = conn.cursor()

    insert_query = '''
        INSERT INTO oglasi (Naslov, Cena, Grad, Lokacija, Kvadratura, Sobnost, Sprat, Link, Datum_preuzimanja)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    '''

    data_to_insert = [
        (
            oglas['Naslov'], oglas['Cena'], oglas['Grad'], oglas['Lokacija'],
            oglas['Kvadratura'], oglas['Sobnost'], oglas['Sprat'], oglas['Link'],
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
    oglasi = soup.find_all('article', itemprop='itemListElement')
    page_data = []
    for oglas in oglasi:
        naslov_tag = oglas.find('h2', itemprop='name')
        naslov = naslov_tag.text.strip() if naslov_tag else 'N/A'
        cena_tag = oglas.find('span', class_='text-price')
        cena = cena_tag.text.strip().replace('\xa0', ' ') if cena_tag else 'N/A'
        link_tag = oglas.find('a', class_='fpogl-list-title')
        link = "https://www.oglasi.rs" + link_tag['href'] if link_tag else 'N/A'
        lokacija_tags = oglas.select('div a[itemprop="category"]')
        lokacija = lokacija_tags[-1].text.strip() if lokacija_tags else 'N/A'
        grad = lokacija_tags[-2].text.strip() if len(lokacija_tags) >= 2 else 'N/A'
        detalji_kontejner = oglas.find_all('div', class_='col-sm-6')
        kvadratura, sobnost, sprat = 'N/A', 'N/A', 'N/A'
        for detalj in detalji_kontejner:
            text_detalja = detalj.text.strip()
            vrednost_tag = detalj.find('strong')
            vrednost = vrednost_tag.text.strip() if vrednost_tag else ''
            if "Kvadratura:" in text_detalja:
                kvadratura = vrednost
            elif "Sobnost:" in text_detalja:
                sobnost = vrednost
            elif "Nivo u zgradi:" in text_detalja:
                sprat = vrednost
        podaci_oglasa = {
            "Naslov": naslov, "Cena": cena, "Grad": grad, "Lokacija": lokacija,
            "Kvadratura": kvadratura, "Sobnost": sobnost, "Sprat": sprat, "Link": link
        }
        page_data.append(podaci_oglasa)
    return page_data


async def fetch_page(session, url, semaphore):
    for attempt in range(RETRY_COUNT):
        async with semaphore:
            if attempt > 0:
                print(f"   -> Ponovni pokušaj ({attempt + 1}/{RETRY_COUNT}) za {url}")
            else:
                print(f"   -> Preuzimam {url}")
            try:
                async with session.get(url, timeout=25) as response:
                    if response.status == 200:
                        return await response.text()
                    else:
                        print(f"   Greška za {url}, Status: {response.status}. Pokušaj {attempt + 1}.")
            except (aiohttp.ClientError, asyncio.TimeoutError) as e:
                print(f"    Greška konekcije za {url} (pokušaj {attempt + 1}): {type(e).__name__}")
        if attempt < RETRY_COUNT - 1:
            await asyncio.sleep(RETRY_DELAY)
    print(f"   Odustajem od {url} nakon {RETRY_COUNT} pokušaja.")
    return None


# IZMENJENO: Glavna funkcija sada radi u serijama (batches)
async def main():
    start_time = time.time()
    init_database()

    print(f"🚀 Započinjem asinhrono preuzimanje (Verzija 5.0 - Obrada u serijama)")
    print(f"Stranice: {START_PAGE}-{END_PAGE} | Veličina serije: {BATCH_SIZE}")

    semaphore = asyncio.Semaphore(MAX_CONCURRENT_REQUESTS)
    total_added_count = 0
    total_successful_pages = 0

    async with aiohttp.ClientSession(headers=HEADERS) as session:
        # Glavna petlja koja ide seriju po seriju
        for i in range(START_PAGE, END_PAGE + 1, BATCH_SIZE):
            batch_start = i
            batch_end = min(i + BATCH_SIZE - 1, END_PAGE)
            print(f"\n--- Obrada serije: Stranice od {batch_start} do {batch_end} ---")

            tasks = [fetch_page(session, BASE_URL.format(page_num), semaphore) for page_num in
                     range(batch_start, batch_end + 1)]
            html_pages_batch = await asyncio.gather(*tasks)

            batch_ads_data = []
            successful_pages_in_batch = 0
            for html in html_pages_batch:
                if html:
                    successful_pages_in_batch += 1
                    batch_ads_data.extend(parse_html_page(html))

            total_successful_pages += successful_pages_in_batch

            if batch_ads_data:
                print(f"   Pronađeno {len(batch_ads_data)} oglasa u ovoj seriji.")
                added_count = save_to_database(batch_ads_data)
                total_added_count += added_count
                print(f"   -> Podaci iz serije sačuvani. Dodato {added_count} redova u bazu.")
            else:
                print("   Nema pronađenih oglasa u ovoj seriji.")

    print("\n" + "=" * 50)
    print("🏁 ZAVRŠENO PREUZIMANJE SVIH SERIJA 🏁")
    print("=" * 50)

    print(f"\n💾 Ukupno uspešno preuzeto stranica: {total_successful_pages} / {END_PAGE - START_PAGE + 1}")
    print(f"🗃️  Ukupno dodato redova u bazu: {total_added_count}")

    end_time = time.time()
    print(f"\n⏱️  Ukupno vreme izvršavanja: {end_time - start_time:.2f} sekundi.")


if __name__ == "__main__":
    asyncio.run(main())