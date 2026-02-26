-- ============================================================
-- Real Estate Serbia - PostgreSQL SCD Type 2 Schema
-- Runs automatically when container is first created
-- ============================================================

CREATE TABLE IF NOT EXISTS ads (
    -- Surrogate key
    id SERIAL PRIMARY KEY,

    -- Business key
    url TEXT NOT NULL,

    -- Data columns
    naslov      TEXT,
    cena        NUMERIC(20, 2),
    cena_po_m2  NUMERIC(20, 2),
    lokacija    TEXT,
    grad        TEXT,
    kvadratura  NUMERIC(8, 2),
    tip_stana   TEXT,
    sobnost     TEXT,
    sprat       TEXT,
    izvor       TEXT NOT NULL,  -- 'nekretnine.rs' or 'oglasi.rs'

    -- SCD Type 2 columns
    valid_from    DATE NOT NULL,
    valid_to      DATE,
    is_current    BOOLEAN DEFAULT TRUE,
    version       INTEGER DEFAULT 1,
    change_reason TEXT,

    -- Audit
    created_at  TIMESTAMP DEFAULT NOW(),
    updated_at  TIMESTAMP DEFAULT NOW(),

    -- Constraints
    CONSTRAINT ads_valid_dates    CHECK (valid_to IS NULL OR valid_from <= valid_to),
    CONSTRAINT ads_version_positive CHECK (version >= 1)
);

-- Indexes
CREATE UNIQUE INDEX IF NOT EXISTS idx_ads_one_current_per_url ON ads(url) WHERE is_current = TRUE;
CREATE INDEX IF NOT EXISTS idx_ads_url_current  ON ads(url, is_current);
CREATE INDEX IF NOT EXISTS idx_ads_valid_range  ON ads(valid_from, valid_to);
CREATE INDEX IF NOT EXISTS idx_ads_grad_current ON ads(grad) WHERE is_current = TRUE;
CREATE INDEX IF NOT EXISTS idx_ads_izvor        ON ads(izvor);

-- View: currently active ads
CREATE OR REPLACE VIEW v_current_ads AS
SELECT
    id, url, naslov, cena, cena_po_m2, lokacija, grad,
    kvadratura, sobnost, sprat, izvor,
    valid_from AS active_since,
    version,
    CURRENT_DATE - valid_from AS days_active
FROM ads
WHERE is_current = TRUE
  AND (change_reason IS NULL OR change_reason != 'removed');

-- View: price change history
CREATE OR REPLACE VIEW v_price_changes AS
SELECT
    a1.url,
    a1.naslov,
    a1.grad,
    a1.cena                                              AS old_price,
    a2.cena                                              AS new_price,
    a2.cena - a1.cena                                    AS price_diff,
    ROUND(((a2.cena - a1.cena) / a1.cena * 100)::numeric, 2) AS price_change_pct,
    a1.valid_to                                          AS change_date,
    a2.change_reason
FROM ads a1
JOIN ads a2 ON a1.url = a2.url AND a2.version = a1.version + 1
WHERE a1.cena IS NOT NULL
  AND a2.cena IS NOT NULL
  AND a1.cena != a2.cena;

-- Validation function: checks SCD integrity
CREATE OR REPLACE FUNCTION validate_scd_integrity()
RETURNS TABLE(issue_type TEXT, url TEXT, details TEXT) AS $$
BEGIN
    -- Test 1: more than one current row per URL
    RETURN QUERY
    SELECT 'MULTIPLE_CURRENT'::TEXT,
           a.url,
           'Found ' || COUNT(*)::TEXT || ' current versions' AS details
    FROM ads a
    WHERE is_current = TRUE
    GROUP BY a.url
    HAVING COUNT(*) > 1;

-- Test 2: current row with valid_to set
    RETURN QUERY
    SELECT 'CURRENT_WITH_END_DATE'::TEXT,
           a.url,
           'is_current=TRUE but valid_to=' || a.valid_to::TEXT AS details
    FROM ads a
    WHERE a.is_current = TRUE AND a.valid_to IS NOT NULL;
END;
$$ LANGUAGE plpgsql;

DO $$
BEGIN
    RAISE NOTICE '✅ Real Estate Serbia - SCD Type 2 schema initialized successfully!';
END $$;