"""
SCD Type 2 utility funkcije za Real Estate Serbia scraper.
Analogno upsert_listing() logici iz AutoScout scrapers.
"""

import psycopg2
import os
from datetime import date


def get_db_connection():
    """
    Kreira konekciju na PostgreSQL.
    Čita kredencijale iz environment varijabli (Docker injektuje ove).
    Ako nema env varijabli, koristi localhost defaults za lokalni razvoj.
    """
    return psycopg2.connect(
        host=os.environ.get('DB_HOST', 'localhost'),
        port=os.environ.get('DB_PORT', '5432'),
        database=os.environ.get('DB_NAME', 'real_estate'),
        user=os.environ.get('DB_USER', 'postgres'),
        password=os.environ.get('DB_PASSWORD', 'postgres123')
    )


def upsert_ad_scd2(cursor, ad_data: dict) -> str:
    """
    SCD Type 2 upsert za jedan oglas.

    Analogno tvojoj upsert_listing() funkciji iz AutoScout scrapers,
    ali umesto asyncpg koristimo psycopg2, i umesto master+history
    tabela imamo jednu 'ads' tabelu sa SCD Type 2 kolonama.

    Logika:
        URL nije u bazi   → INSERT (version=1, is_current=TRUE)
        URL postoji:
            Cena/kvadratura se promenila → zatvori stari red + INSERT novi
            Ništa se nije promenilo      → samo ažuriraj updated_at

    Returns:
        'inserted', 'changed', ili 'unchanged'
    """
    url   = ad_data['url']
    today = date.today()

    # Proveri da li postoji aktivan oglas sa ovim URL-om
    # Analogno: existing = await conn.fetchrow('SELECT ... FROM ads WHERE listing_id = $1')
    cursor.execute("""
        SELECT id, cena, kvadratura, version
        FROM ads
        WHERE url = %s AND is_current = TRUE
    """, (url,))

    existing = cursor.fetchone()

    # -------------------------------------------------------
    # NOVI OGLAS
    # -------------------------------------------------------
    if existing is None:
        cursor.execute("""
            INSERT INTO ads (
                url, naslov, cena, cena_po_m2, lokacija, grad,
                kvadratura, tip_stana, sobnost, sprat, izvor,
                valid_from, valid_to, is_current, version, change_reason
            ) VALUES (
                %s, %s, %s, %s, %s, %s,
                %s, %s, %s, %s, %s,
                %s, NULL, TRUE, 1, 'first_seen'
            )
        """, (
            url,
            ad_data.get('naslov'),
            ad_data.get('cena'),
            ad_data.get('cena_po_m2'),
            ad_data.get('lokacija'),
            ad_data.get('grad'),
            ad_data.get('kvadratura'),
            ad_data.get('tip_stana'),
            ad_data.get('sobnost'),
            ad_data.get('sprat'),
            ad_data['izvor'],
            today
        ))
        return 'inserted'

    # -------------------------------------------------------
    # POSTOJEĆI OGLAS — proveri promene
    # -------------------------------------------------------
    ad_id, old_cena, old_kvadratura, current_version = existing

    new_cena       = ad_data.get('cena')
    new_kvadratura = ad_data.get('kvadratura')

    # Poređenje — isto kao _detect_changes() u AutoScout kodu
    # Kastujemo u float jer iz HTML-a mogu doći kao Decimal vs float
    def normalize(val):
        try:
            return float(val) if val is not None else None
        except (TypeError, ValueError):
            return val

    cena_changed       = normalize(old_cena) != normalize(new_cena)
    kvadratura_changed = normalize(old_kvadratura) != normalize(new_kvadratura)

    if cena_changed or kvadratura_changed:
        # Odredi razlog promene
        if cena_changed and new_cena and old_cena:
            change_reason = 'price_decreased' if new_cena < old_cena else 'price_increased'
        else:
            change_reason = 'data_updated'

        # Korak 1: Zatvori stari red
        # Analogno: UPDATE ads SET is_active = FALSE ... u AutoScout kodu
        cursor.execute("""
            UPDATE ads
            SET valid_to    = %s,
                is_current  = FALSE,
                updated_at  = NOW()
            WHERE id = %s
        """, (today, ad_id))

        # Korak 2: Insert nova verzija
        cursor.execute("""
            INSERT INTO ads (
                url, naslov, cena, cena_po_m2, lokacija, grad,
                kvadratura, tip_stana, sobnost, sprat, izvor,
                valid_from, valid_to, is_current, version, change_reason
            ) VALUES (
                %s, %s, %s, %s, %s, %s,
                %s, %s, %s, %s, %s,
                %s, NULL, TRUE, %s, %s
            )
        """, (
            url,
            ad_data.get('naslov'),
            ad_data.get('cena'),
            ad_data.get('cena_po_m2'),
            ad_data.get('lokacija'),
            ad_data.get('grad'),
            ad_data.get('kvadratura'),
            ad_data.get('tip_stana'),
            ad_data.get('sobnost'),
            ad_data.get('sprat'),
            ad_data['izvor'],
            today,
            current_version + 1,
            change_reason
        ))
        return 'changed'

    else:
        # Bez promena — samo refresh timestamp
        cursor.execute("""
            UPDATE ads SET updated_at = NOW() WHERE id = %s
        """, (ad_id,))
        return 'unchanged'


def mark_removed_ads(cursor, scraped_urls: list, izvor: str) -> int:
    """
    Oglasi koji nisu viđeni u današnjem run-u → is_current = FALSE.
    Analogno mark_inactive_listings() iz AutoScout koda.

    Args:
        scraped_urls: lista svih URL-ova koje smo danas videli
        izvor: 'nekretnine.rs' ili 'oglasi.rs'

    Returns:
        Broj označenih oglasa
    """
    if not scraped_urls:
        return 0

    today = date.today()

    cursor.execute("""
        UPDATE ads
        SET valid_to    = %s,
            is_current  = FALSE,
            updated_at  = NOW(),
            change_reason = 'removed'
        WHERE izvor       = %s
          AND is_current  = TRUE
          AND url NOT IN %s
          AND valid_from  < %s
    """, (today, izvor, tuple(scraped_urls), today))

    return cursor.rowcount