DROP SCHEMA IF EXISTS vsc_api CASCADE;
CREATE SCHEMA IF NOT EXISTS vsc_api AUTHORIZATION vsc_app;
GRANT USAGE ON SCHEMA vsc_api TO vsc_user;
GRANT USAGE ON SCHEMA vsc_app TO vsc_user;
GRANT SELECT ON ALL TABLES IN SCHEMA vsc_api TO vsc_user;
GRANT SELECT ON ALL TABLES IN SCHEMA vsc_app TO vsc_user;
GRANT SELECT ON TABLE hive.vsc_app_accounts TO vsc_user;

-- GET /
CREATE OR REPLACE FUNCTION vsc_api.home()
RETURNS jsonb
AS
$function$
DECLARE
    _last_processed_block INTEGER;
    _db_version INTEGER;
BEGIN
    SELECT last_processed_block, db_version INTO _last_processed_block, _db_version FROM vsc_app.state;
    RETURN jsonb_build_object(
        'last_processed_block', _last_processed_block,
        'db_version', _db_version
    );
END
$function$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_api.get_block_by_hash(blk_hash VARCHAR)
RETURNS jsonb
AS
$function$
DECLARE
    _announced_in_op BIGINT;
    _block_id INTEGER;
    _announced_in_tx_id BIGINT;
    _announced_in_tx TEXT;
BEGIN
    SELECT id, announced_in_op INTO _block_id, _announced_in_op
        FROM vsc_app.blocks
        WHERE vsc_app.blocks.block_hash = blk_hash
        LIMIT 1;
    SELECT l1_op.op_id INTO _announced_in_tx_id
        FROM vsc_app.l1_operations l1_op
        WHERE vsc_app.l1_operations.id = _announced_in_op;
    SELECT htx.trx_hash::TEXT INTO _announced_in_tx FROM hive.transactions_view htx
        JOIN hive.operations_view ON
            hive.operations_view.block_num = hive.transactions_view.block_num AND
            hive.operations_view.trx_in_block = hive.transactions_view.trx_in_block
        WHERE hive.operations_view.id = _announced_in_tx_id;
    
    RETURN jsonb_build_object(
        'id', _block_id,
        'block_hash', blk_hash,
        'announced_in_tx', _announced_in_tx
    );
END
$function$
LANGUAGE plpgsql STABLE;