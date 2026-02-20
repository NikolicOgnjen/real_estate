import asyncio
import aiohttp
from bs4 import BeautifulSoup
import time
import re
from scd_utils import get_db_connection, upsert_ad_scd2, mark_removed_ads

# --- SETTINGS ---
START_PAGE = 1
END_PAGE = 10
BATCH_SIZE = 100
MAX_CONCURRENT_REQUESTS = 5
RETRY_COUNT = 3
RETRY_DELAY = 5
IZVOR = 'oglasi.rs'

BASE_URL = "https://www.oglasi.rs/nekretnine/prodaja-stanova?p={}"
HEADERS = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36'
}


# --- DATA NORMALIZATION ---
# HTML scraper returns everything as strings, PostgreSQL expects NUMERIC types

def _parse_price(price_str: str):
    """'123.456 €' → 123456.0"""
    if not price_str or price_str == 'N/A':
        return None
    try:
        cleaned = re.sub(r'[^\d,.]', '', price_str).replace('.', '').replace(',', '.')
        return float(cleaned)
    except (ValueError, AttributeError):
        return None


def _parse_area(area_str: str):
    """'75 m²' → 75.0"""
    if not area_str or area_str == 'N/A':
        return None
    try:
        match = re.search(r'[\d,.]+', area_str)
        return float(match.group().replace(',', '.')) if match else None
    except (ValueError, AttributeError):
        return None


# --- HTML PARSING ---

def parse_html_page(html_content):
    """Parses one listing page, returns list of raw ad dicts."""
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

        # oglasi.rs provides city and neighborhood separately
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

        page_data.append({
            "Naslov": naslov, "Cena": cena, "Grad": grad, "Lokacija": lokacija,
            "Kvadratura": kvadratura, "Sobnost": sobnost, "Sprat": sprat, "Link": link
        })

    return page_data


# --- HTTP ---

async def fetch_page(session, url, semaphore):
    """Fetches a single page with retry logic."""
    for attempt in range(RETRY_COUNT):
        async with semaphore:
            if attempt > 0:
                print(f"   -> Retry ({attempt + 1}/{RETRY_COUNT}) for {url}")
            else:
                print(f"   -> Fetching {url}")
            try:
                async with session.get(url, timeout=25) as response:
                    if response.status == 200:
                        return await response.text()
                    else:
                        print(f"   Status {response.status} for {url}. Attempt {attempt + 1}.")
            except (aiohttp.ClientError, asyncio.TimeoutError) as e:
                print(f"   Connection error for {url} (attempt {attempt + 1}): {type(e).__name__}")
        if attempt < RETRY_COUNT - 1:
            await asyncio.sleep(RETRY_DELAY)

    print(f"   Giving up on {url} after {RETRY_COUNT} attempts.")
    return None


# --- MAIN ---

async def main():
    start_time = time.time()

    print(f"🚀 Starting oglasi.rs scraper")
    print(f"Pages: {START_PAGE}-{END_PAGE} | Batch size: {BATCH_SIZE}")

    semaphore            = asyncio.Semaphore(MAX_CONCURRENT_REQUESTS)
    scraped_urls         = []  # collects all seen URLs for removed ad detection
    total_ads_all_ranges = 0
    stats                = {'inserted': 0, 'changed': 0, 'unchanged': 0}

    # Single PostgreSQL connection for the entire run
    conn   = get_db_connection()
    cursor = conn.cursor()

    try:
        async with aiohttp.ClientSession(headers=HEADERS) as session:
            for i in range(START_PAGE, END_PAGE + 1, BATCH_SIZE):
                batch_start = i
                batch_end   = min(i + BATCH_SIZE - 1, END_PAGE)
                print(f"\n--- Batch: pages {batch_start} to {batch_end} ---")

                # Fetch all pages in batch concurrently
                tasks = [
                    fetch_page(session, BASE_URL.format(page_num), semaphore)
                    for page_num in range(batch_start, batch_end + 1)
                ]
                html_pages_batch = await asyncio.gather(*tasks)

                # Parse all fetched pages
                batch_ads = []
                for html in html_pages_batch:
                    if html:
                        batch_ads.extend(parse_html_page(html))

                if not batch_ads:
                    print("   No ads found in this batch.")
                    continue

                print(f"   ✅ Found {len(batch_ads)} ads in batch.")

                # Normalize each ad and run SCD Type 2 upsert
                for ad in batch_ads:
                    ad_normalized = {
                        'url':        ad['Link'],
                        'naslov':     ad['Naslov'],
                        'cena':       _parse_price(ad['Cena']),
                        'cena_po_m2': None,           # not available on oglasi.rs
                        'lokacija':   ad['Lokacija'],
                        'grad':       ad['Grad'],      # oglasi.rs provides city directly
                        'kvadratura': _parse_area(ad['Kvadratura']),
                        'tip_stana':  None,            # not available on oglasi.rs
                        'sobnost':    ad['Sobnost'],
                        'sprat':      ad['Sprat'],
                        'izvor':      IZVOR
                    }

                    result = upsert_ad_scd2(cursor, ad_normalized)
                    stats[result] += 1

                    if ad_normalized['url'] != 'N/A':
                        scraped_urls.append(ad_normalized['url'])

                total_ads_all_ranges += len(batch_ads)

                # Commit after each batch
                conn.commit()
                print(f"   💾 Batch committed. Stats so far: {stats}")

        # Mark ads not seen today as removed (SCD Type 2 close)
        removed = mark_removed_ads(cursor, scraped_urls, IZVOR)
        conn.commit()
        print(f"🗑️  Marked {removed} ads as removed")

    except Exception as e:
        conn.rollback()  # undo uncommitted changes on error
        print(f"❌ Critical error: {e}")
        raise
    finally:
        cursor.close()
        conn.close()

    print("\n" + "=" * 50)
    print("🏁 SCRAPING COMPLETE")
    print("=" * 50)
    print(f"\n📊 Final stats: {stats}")
    print(f"🗃️  Total ads processed: {total_ads_all_ranges}")
    print(f"⏱️  Total time: {time.time() - start_time:.2f}s")


if __name__ == "__main__":
    asyncio.run(main())