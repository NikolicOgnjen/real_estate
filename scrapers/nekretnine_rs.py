import asyncio
import aiohttp
from bs4 import BeautifulSoup
import time
import re
from scd_utils import get_db_connection, upsert_ad_scd2, mark_removed_ads

# --- SETTINGS ---
MAX_CONCURRENT_REQUESTS = 5
RETRY_COUNT = 3
RETRY_DELAY = 5
IZVOR = 'nekretnine.rs'

# Price ranges to cover all listings (site limits results per search)
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
    (500000, 9999999)
]

BASE_URL = "https://www.nekretnine.rs/stambeni-objekti/izdavanje-prodaja/prodaja/cena/{min_price}_{max_price}/lista/po-stranici/20/stranica/{page}/"
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


def _extract_grad(lokacija: str):
    """'Beograd, Novi Beograd, Blok 45' → 'Beograd'"""
    if not lokacija or lokacija == 'N/A':
        return None
    return lokacija.split(',')[0].strip()


# --- HTML PARSING ---

def parse_html_page(html_content):
    """Parses one listing page, returns list of raw ad dicts."""
    soup = BeautifulSoup(html_content, 'lxml')
    oglasi = soup.find_all('div', class_='row offer')
    if not oglasi:
        return []
    page_data = []

    for oglas in oglasi:
        try:
            url_tag = oglas.find('a', href=re.compile(r'/stambeni-objekti/'))
            url = "https://www.nekretnine.rs" + url_tag['href'] if url_tag else 'N/A'

            naslov_tag = oglas.find('h2', class_='offer-title')
            naslov = naslov_tag.text.strip() if naslov_tag else 'N/A'

            cena_tag = oglas.find('p', class_='offer-price')
            cena = 'N/A'
            if cena_tag:
                cena_span = cena_tag.find('span')
                if cena_span:
                    cena = cena_span.text.strip()

            cena_po_m2 = 'N/A'
            if cena_tag:
                cena_m2_tag = cena_tag.find('small', class_='custom-offer-style')
                if cena_m2_tag:
                    cena_po_m2 = cena_m2_tag.text.strip()

            lokacija_tag = oglas.find('p', class_='offer-location')
            lokacija = lokacija_tag.text.strip() if lokacija_tag else 'N/A'

            kvadratura = 'N/A'
            kvadratura_tags = oglas.find_all('p', class_='offer-price')
            for tag in kvadratura_tags:
                if 'offer-price--invert' in tag.get('class', []):
                    span = tag.find('span')
                    if span and 'm²' in span.text:
                        kvadratura = span.text.strip()
                        break

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

            page_data.append({
                "Naslov": naslov,
                "Cena": cena,
                "Cena_po_m2": cena_po_m2,
                "Lokacija": lokacija,
                "Kvadratura": kvadratura,
                "Tip_stana": tip_stana,
                "Datum_oglasa": datum_oglasa,
                "URL": url
            })

        except Exception as e:
            print(f"   ⚠️  Parsing error: {e}")
            continue

    return page_data


# --- HTTP ---

async def fetch_page(session, url, semaphore):
    """Fetches a single page with retry logic."""
    for attempt in range(RETRY_COUNT):
        async with semaphore:
            if attempt > 0:
                print(f"   -> Retry ({attempt + 1}/{RETRY_COUNT}) for {url}")
            try:
                async with session.get(url, timeout=25) as response:
                    if response.status == 200:
                        return await response.text()
                    else:
                        print(f"   ❌ Status {response.status} for {url}. Attempt {attempt + 1}.")
            except (aiohttp.ClientError, asyncio.TimeoutError) as e:
                print(f"   🔥 Connection error for {url} (attempt {attempt + 1}): {type(e).__name__}")

        if attempt < RETRY_COUNT - 1:
            await asyncio.sleep(RETRY_DELAY)

    print(f"   💀 Giving up on {url} after {RETRY_COUNT} attempts.")
    return None


# --- SCRAPING + SCD UPSERT ---

async def process_price_range(session, semaphore, min_price, max_price,
                               cursor, scraped_urls: list):
    """
    Scrapes all pages for one price range.
    For each ad: normalizes data, calls SCD Type 2 upsert, tracks URL.
    """
    print(f"\n{'=' * 60}")
    print(f"💰 Price range: {min_price:,} - {max_price:,} €")
    print(f"{'=' * 60}")

    total_ads_in_range = 0
    stats = {'inserted': 0, 'changed': 0, 'unchanged': 0}
    page = 1

    while True:
        print(f"\n--- Page {page} ({min_price:,}-{max_price:,} €) ---")

        url = BASE_URL.format(min_price=min_price, max_price=max_price, page=page)
        html = await fetch_page(session, url, semaphore)

        if not html:
            print(f"   ⚠️  Could not fetch page {page}. Stopping this range.")
            break

        ads_data = parse_html_page(html)

        if not ads_data:
            print(f"   🛑 No ads on page {page}. End of range.")
            break

        print(f"   ✅ Found {len(ads_data)} ads on page {page}.")

        # Normalize each ad and run SCD Type 2 upsert
        for ad in ads_data:
            ad_normalized = {
                'url':        ad['URL'],
                'naslov':     ad['Naslov'],
                'cena':       _parse_price(ad['Cena']),
                'cena_po_m2': _parse_price(ad['Cena_po_m2']),
                'lokacija':   ad['Lokacija'],
                'grad':       _extract_grad(ad['Lokacija']),
                'kvadratura': _parse_area(ad['Kvadratura']),
                'tip_stana':  ad['Tip_stana'],
                'sobnost':    None,  # not available on nekretnine.rs
                'sprat':      None,  # not available on nekretnine.rs
                'izvor':      IZVOR
            }

            result = upsert_ad_scd2(cursor, ad_normalized)
            stats[result] += 1

            if ad_normalized['url'] != 'N/A':
                scraped_urls.append(ad_normalized['url'])

        total_ads_in_range += len(ads_data)
        print(f"   📊 Page stats: {stats}")

        page += 1
        await asyncio.sleep(0.5)

    print(f"\n✅ Range {min_price:,}-{max_price:,} € done. Total: {total_ads_in_range} ads.")
    return total_ads_in_range


# --- MAIN ---

async def main():
    start_time = time.time()

    print(f"🚀 Starting nekretnine.rs scraper")
    print(f"📊 Price ranges: {len(PRICE_RANGES)}")

    semaphore            = asyncio.Semaphore(MAX_CONCURRENT_REQUESTS)
    scraped_urls         = []  # collects all seen URLs for removed ad detection
    total_ads_all_ranges = 0   # running total across all price ranges

    # Single PostgreSQL connection for the entire run
    conn   = get_db_connection()
    cursor = conn.cursor()

    try:
        async with aiohttp.ClientSession(headers=HEADERS) as session:
            for min_price, max_price in PRICE_RANGES:
                ads_count = await process_price_range(
                    session, semaphore, min_price, max_price,
                    cursor, scraped_urls
                )
                total_ads_all_ranges += ads_count
                conn.commit()  # commit after each price range
                print(f"💾 Committed range {min_price:,}-{max_price:,} €")

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

    print("\n" + "=" * 60)
    print("🏁 SCRAPING COMPLETE")
    print("=" * 60)
    print(f"\n🗃️  Total ads processed: {total_ads_all_ranges}")
    print(f"⏱️  Total time: {time.time() - start_time:.2f}s")


if __name__ == "__main__":
    asyncio.run(main())