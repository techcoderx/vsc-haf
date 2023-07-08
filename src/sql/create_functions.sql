DROP TYPE IF EXISTS vsc_app.op_type CASCADE;
CREATE TYPE vsc_app.op_type AS (
    id BIGINT,
    block_num INT,
    trx_in_block SMALLINT,
    trx_id TEXT,
    created_at TIMESTAMP,
    body TEXT
);

CREATE OR REPLACE FUNCTION vsc_app.enum_op(IN _first_block INT, IN _last_block INT)
RETURNS SETOF vsc_app.op_type
AS
$function$
BEGIN
    -- Fetch custom_json and account_update operations
    SELECT
        id,
        hive.operations_view.block_num,
        hive.transactions_view.trx_in_block,
        encode(hive.transactions_view.trx_hash::bytea, 'hex') AS trx_id,
        created_at,
        body::TEXT
    FROM hive.operations_view
    JOIN hive.blocks_view ON hive.blocks_view.num = hive.operations_view.block_num
    JOIN hive.transactions_view ON
        hive.transactions_view.block_num = hive.operations_view.block_num AND
        hive.transactions_view.trx_in_block = hive.operations_view.trx_in_block
    WHERE hive.operations_view.block_num >= _first_block AND hive.operations_view.block_num <= _last_block AND
        (op_type_id=18 OR op_type_id=10)
    ORDER BY block_num, id;
END
$function$
LANGUAGE plpgsql STABLE;

-- Process transactions
-- Example code here shows querying user id by account name from accounts state provider
CREATE OR REPLACE FUNCTION vsc_app.process_tx(_username VARCHAR)
RETURNS void
AS
$function$
DECLARE
    _hive_user_id INTEGER = NULL;
BEGIN
    SELECT id INTO _hive_user_id FROM hive.vsc_app_accounts WHERE name=_username;
    IF _hive_user_id IS NULL THEN
        RAISE EXCEPTION 'Could not process non-existent user %', _username;
    END IF;
END
$function$
LANGUAGE plpgsql VOLATILE;