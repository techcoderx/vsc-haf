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
    RETURN QUERY
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
CREATE OR REPLACE FUNCTION vsc_app.process_operation(_username VARCHAR, _op_id BIGINT, _op_type INTEGER)
RETURNS BIGINT
AS
$function$
DECLARE
    _hive_user_id INTEGER = NULL;
    _vsc_op_id BIGINT = NULL;
BEGIN
    SELECT id INTO _hive_user_id FROM hive.vsc_app_accounts WHERE name=_username;
    IF _hive_user_id IS NULL THEN
        RAISE EXCEPTION 'Could not process non-existent user %', _username;
    END IF;

    INSERT INTO vsc_app.l1_operations(user_id, op_id, op_type)
        VALUES(_hive_user_id, _op_id, _op_type)
        RETURNING id INTO _vsc_op_id;

    RETURN _vsc_op_id;
END
$function$
LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION vsc_app.update_witness(_username VARCHAR, _did VARCHAR, _enabled BOOLEAN, _op_id BIGINT)
RETURNS void
AS
$function$
DECLARE
    _hive_user_id INTEGER = NULL;
    _enabled_at INTEGER = NULL;
    _disabled_at INTEGER = NULL;
    _witness_exists BOOLEAN = NULL;
BEGIN
    SELECT id INTO _hive_user_id FROM hive.vsc_app_accounts WHERE name=_username;
    IF _hive_user_id IS NULL THEN
        RAISE EXCEPTION 'Could not process non-existent user %', _username;
    END IF;

    SELECT EXISTS INTO _witness_exists(
        SELECT 1 FROM vsc_app.witnesses WHERE id=_hive_user_id
    );

    IF _witness_exists IS FALSE THEN
        IF _enabled IS TRUE THEN
            INSERT INTO vsc_app.witnesses(id, did, enabled, enabled_at)
                VALUES (_hive_user_id, _did, TRUE, _op_id);
        ELSE
            RETURN;
        END IF;
    ELSE
        IF _enabled IS FALSE THEN
            UPDATE vsc_app.witnesses SET
                enabled = FALSE,
                did = _did,
                disabled_at = _op_id
            WHERE id = _hive_user_id;
        ELSE
            UPDATE vsc_app.witnesses SET
                enabled = TRUE,
                did = _did,
                enabled_at = _op_id
            WHERE id = _hive_user_id;
        END IF;
    END IF;
END
$function$
LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION vsc_app.trust_did(_did VARCHAR, _is_trusted BOOLEAN)
RETURNS void
AS
$function$
BEGIN
    INSERT INTO vsc_app.trusted_dids(did, trusted)
        VALUES(_did, _is_trusted)
        ON CONFLICT (did) DO UPDATE
        SET trusted=_is_trusted;
END
$function$
LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION vsc_app.insert_block(_announced_in_op BIGINT, _block_hash VARCHAR)
RETURNS void
AS
$function$
BEGIN
    INSERT INTO vsc_app.blocks(announced_in_op, block_hash)
        VALUES(_announced_in_op, _block_hash);
END
$function$
LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION vsc_app.insert_contract(
    _created_in_op BIGINT,
    _contract_id VARCHAR,
    _contract_name VARCHAR,
    _manifest_id VARCHAR,
    _code_hash VARCHAR)
RETURNS void
AS
$function$
BEGIN
    INSERT INTO vsc_app.blocks(created_in_op, contract_id, name, manifest_id, code)
        VALUES(_created_in_op, _contract_id, _contract_name, _manifest_id, _code_hash);
END
$function$
LANGUAGE plpgsql VOLATILE;

CREATE OR REPLACE FUNCTION vsc_app.update_contract_commitment(
    _contract_id VARCHAR,
    _node_identity VARCHAR,
    _is_active BOOLEAN
)
RETURNS void
AS
$function$
BEGIN
    INSERT INTO vsc_app.contract_commitments(contract_id, node_identity, is_active)
        VALUES(_contract_id, _node_identity, _is_active)
        ON CONFLICT (contract_id, node_identity) DO UPDATE
        SET is_active=_is_active;
END
$function$
LANGUAGE plpgsql VOLATILE;