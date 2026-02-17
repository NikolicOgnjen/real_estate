-- ============================================================
-- Real Estate Serbia — PostgreSQL schema
-- Pokreće se automatski kada se kontejner prvi put kreira
-- ============================================================

-- Kreiranje tabele za nekretnine.rs oglase
CREATE TABLE IF NOT EXISTS oglasi_nekretnine_rs (
    id                  SERIAL PRIMARY KEY,
    naslov              TEXT,
    cena                NUMERIC(12, 2),
    cena_po_m2          NUMERIC(10, 2),
    lokacija            TEXT,
    kvadratura          NUMERIC(8, 2),
    tip_stana           TEXT,
    datum_oglasa        TEXT,
    url                 TEXT,
    datum_preuzimanja   DATE NOT NULL DEFAULT CURRENT_DATE,
    created_at          TIMESTAMP DEFAULT NOW()
);

-- Kreiranje tabele za oglasi.rs oglase
CREATE TABLE IF NOT EXISTS oglasi_oglasi_rs (
    id                  SERIAL PRIMARY KEY,
    naslov              TEXT,
    cena                NUMERIC(12, 2),
    grad                TEXT,
    lokacija            TEXT,
    kvadratura          NUMERIC(8, 2),
    sobnost             TEXT,
    sprat               TEXT,
    link                TEXT,
    datum_preuzimanja   DATE NOT NULL DEFAULT CURRENT_DATE,
    created_at          TIMESTAMP DEFAULT NOW()
);

-- Indeksi za brže filtriranje u Shiny aplikaciji
CREATE INDEX IF NOT EXISTS idx_nekretnine_rs_grad     ON oglasi_nekretnine_rs (lokacija);
CREATE INDEX IF NOT EXISTS idx_nekretnine_rs_cena     ON oglasi_nekretnine_rs (cena);
CREATE INDEX IF NOT EXISTS idx_nekretnine_rs_datum    ON oglasi_nekretnine_rs (datum_preuzimanja);

CREATE INDEX IF NOT EXISTS idx_oglasi_rs_grad         ON oglasi_oglasi_rs (grad);
CREATE INDEX IF NOT EXISTS idx_oglasi_rs_cena         ON oglasi_oglasi_rs (cena);
CREATE INDEX IF NOT EXISTS idx_oglasi_rs_datum        ON oglasi_oglasi_rs (datum_preuzimanja);

-- ============================================================
-- View koji kombinuje obe tabele (korisno za Shiny app)
-- ============================================================
CREATE OR REPLACE VIEW v_all_listings AS
    SELECT
        id,
        NULL            AS naslov,
        cena,
        cena_po_m2,
        lokacija        AS lokacija,
        NULL            AS grad,
        kvadratura,
        datum_preuzimanja,
        'nekretnine.rs' AS izvor,
        url             AS link
    FROM oglasi_nekretnine_rs

    UNION ALL

    SELECT
        id,
        naslov,
        cena,
        NULL            AS cena_po_m2,
        lokacija,
        grad,
        kvadratura,
        datum_preuzimanja,
        'oglasi.rs'     AS izvor,
        link
    FROM oglasi_oglasi_rs;

-- Potvrda da je inicijalizacija prošla
DO $$
BEGIN
    RAISE NOTICE '✅ Real Estate Serbia baza inicijalizovana uspešno!';
END $$;