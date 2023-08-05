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
    _l1_tx TEXT;
    _announcer_id INTEGER;
    _announcer TEXT;
BEGIN
    SELECT id, announced_in_op, announcer INTO _block_id, _announced_in_op, _announcer_id
        FROM vsc_app.blocks
        WHERE vsc_app.blocks.block_hash = blk_hash
        LIMIT 1;
    IF _block_id IS NULL THEN
        RETURN jsonb_build_object('error', 'Block does not exist');
    END IF;
    SELECT l1_op.op_id INTO _announced_in_tx_id
        FROM vsc_app.l1_operations l1_op
        WHERE l1_op.id = _announced_in_op;
    SELECT encode(htx.trx_hash::bytea, 'hex') INTO _l1_tx
        FROM hive.transactions_view htx
        JOIN hive.operations_view ON
            hive.operations_view.block_num = htx.block_num AND
            hive.operations_view.trx_in_block = htx.trx_in_block
        WHERE hive.operations_view.id = _announced_in_tx_id;
    SELECT name INTO _announcer FROM hive.vsc_app_accounts WHERE id=_announcer_id;
    
    RETURN jsonb_build_object(
        'id', _block_id,
        'block_hash', blk_hash,
        'announced_in_tx', _l1_tx,
        'announcer', _announcer
    );
END
$function$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_api.get_block_by_id(blk_id INTEGER)
RETURNS jsonb
AS
$function$
DECLARE
    _announced_in_op BIGINT;
    _block_hash VARCHAR;
    _announced_in_tx_id BIGINT;
    _l1_tx TEXT;
    _announcer_id INTEGER;
    _announcer TEXT;
    _l1_block INTEGER;
BEGIN
    SELECT block_hash, announced_in_op, announcer INTO _block_hash, _announced_in_op, _announcer_id
        FROM vsc_app.blocks
        WHERE vsc_app.blocks.id = blk_id;
    IF _block_hash IS NULL THEN
        RETURN jsonb_build_object('error', 'Block does not exist');
    END IF;
    SELECT l1_op.op_id INTO _announced_in_tx_id
        FROM vsc_app.l1_operations l1_op
        WHERE l1_op.id = _announced_in_op;
    SELECT encode(htx.trx_hash::bytea, 'hex'), htx.block_num INTO _l1_tx, _l1_block
        FROM hive.transactions_view htx
        JOIN hive.operations_view ON
            hive.operations_view.block_num = htx.block_num AND
            hive.operations_view.trx_in_block = htx.trx_in_block
        WHERE hive.operations_view.id = _announced_in_tx_id;
    SELECT name INTO _announcer FROM hive.vsc_app_accounts WHERE id=_announcer_id;
    
    RETURN jsonb_build_object(
        'id', blk_id,
        'block_hash', _block_hash,
        'announcer', _announcer,
        'l1_tx', _l1_tx,
        'l1_block', _l1_block
    );
END
$function$
LANGUAGE plpgsql STABLE;

DROP TYPE IF EXISTS vsc_api.block_type CASCADE;
CREATE TYPE vsc_api.block_type AS (
    id INTEGER,
    announced_in_op BIGINT,
    block_hash VARCHAR,
    announcer INTEGER
);

CREATE OR REPLACE FUNCTION vsc_api.get_block_range(blk_id_start INTEGER, blk_count INTEGER)
RETURNS jsonb
AS
$function$
DECLARE
    b vsc_api.block_type;
    _block_details vsc_api.block_type[];
    _blocks jsonb[] DEFAULT '{}';
    _announced_in_tx_id BIGINT;
    _l1_tx TEXT;
    _announcer TEXT;
    _l1_block INTEGER;
BEGIN
    IF blk_count > 1000 OR blk_count <= 0 THEN
        RETURN jsonb_build_object(
            'error', 'blk_count must be between 1 and 1000'
        );
    END IF;
    SELECT ARRAY(
        SELECT ROW(vsc_app.blocks.*)::vsc_api.block_type
            FROM vsc_app.blocks
            WHERE vsc_app.blocks.id >= blk_id_start AND vsc_app.blocks.id < blk_id_start+blk_count
    ) INTO _block_details;
    FOREACH b IN ARRAY _block_details
    LOOP
        SELECT l1_op.op_id INTO _announced_in_tx_id
            FROM vsc_app.l1_operations l1_op
            WHERE l1_op.id = b.announced_in_op;
        SELECT encode(htx.trx_hash::bytea, 'hex'), htx.block_num INTO _l1_tx, _l1_block
            FROM hive.transactions_view htx
            JOIN hive.operations_view ON
                hive.operations_view.block_num = htx.block_num AND
                hive.operations_view.trx_in_block = htx.trx_in_block
            WHERE hive.operations_view.id = _announced_in_tx_id;
        SELECT name INTO _announcer FROM hive.vsc_app_accounts WHERE id=b.announcer;
        SELECT ARRAY_APPEND(_blocks, jsonb_build_object(
            'id', b.id,
            'block_hash', b.block_hash,
            'announcer', _announcer,
            'l1_tx', _l1_tx,
            'l1_block', _l1_block
        )) INTO _blocks;
    END LOOP;

    RETURN jsonb_build_object(
        'count', ARRAY_LENGTH(_block_details, 1),
        'blocks', _blocks
    );
END
$function$
LANGUAGE plpgsql STABLE;

DROP TYPE IF EXISTS vsc_api.l1_op_type CASCADE;
CREATE TYPE vsc_api.l1_op_type AS (
    id BIGINT,
    name VARCHAR,
    op_type INTEGER,
    block_num INTEGER,
    body TEXT
);

CREATE OR REPLACE FUNCTION vsc_api.get_l1_operations_by_l1_blocks(l1_blk_start INTEGER, l1_blk_count INTEGER)
RETURNS jsonb
AS
$function$
DECLARE
    op vsc_api.l1_op_type;
    ops vsc_api.l1_op_type[];
    ops_arr jsonb[] DEFAULT '{}';
BEGIN
    SELECT ARRAY(
        SELECT ROW(o.id, hive.vsc_app_accounts.name, o.op_type, hive.operations_view.block_num, hive.operations_view.body::TEXT)::vsc_api.l1_op_type
            FROM vsc_app.l1_operations o
            JOIN hive.operations_view ON
                hive.operations_view.id = o.op_id
            JOIN hive.vsc_app_accounts ON
                hive.vsc_app_accounts.id = o.user_id
            WHERE hive.operations_view.block_num >= l1_blk_start AND hive.operations_view.block_num < l1_blk_start+l1_blk_count
    ) INTO ops;
    
    FOREACH op IN ARRAY ops
    LOOP
        SELECT ARRAY_APPEND(ops_arr, jsonb_build_object(
            'id', op.id,
            'username', op.name,
            'type', op.op_type,
            'l1_block', op.block_num,
            'payload', (op.body::jsonb->'value'->>'json')::jsonb
        )) INTO ops_arr;
    END LOOP;
    
    RETURN jsonb_build_object(
        'count', ARRAY_LENGTH(ops, 1),
        'ops', ops_arr
    );
END
$function$
LANGUAGE plpgsql STABLE;