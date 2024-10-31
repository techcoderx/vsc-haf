SET ROLE vsc_owner;

CREATE OR REPLACE FUNCTION vsc_app.base64url_to_bytea(base64url TEXT)
RETURNS bytea AS $$
DECLARE
    base64 TEXT;
BEGIN
    -- Replace URL-safe characters
    base64 := REPLACE(REPLACE(REPLACE(base64url, '-', '+'), '_', '/'), ' ', '');
    
    -- Add padding if necessary
    WHILE LENGTH(base64) % 4 <> 0 LOOP
        base64 := base64 || '=';
    END LOOP;

    -- Decode the base64 string
    RETURN DECODE(base64, 'base64');
END $$
LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION vsc_app.is_valid_base64url(base64url TEXT)
RETURNS BOOLEAN AS $$
DECLARE
    -- Define a regex pattern for Base64 URL
    valid_pattern TEXT := '^[A-Za-z0-9_\-]+$';
    padding_needed INT;
BEGIN
    -- Check if the string matches the valid Base64 URL pattern
    IF NOT base64url ~ valid_pattern THEN
        RETURN FALSE;
    END IF;

    -- Calculate padding needed
    padding_needed := LENGTH(base64url) % 4;

    -- If padding is needed, it should not exceed 2
    IF padding_needed > 2 THEN
        RETURN FALSE;
    END IF;

    RETURN TRUE;
END $$
LANGUAGE plpgsql IMMUTABLE;