SET ROLE vsc_owner;

DROP SCHEMA IF EXISTS vsc_mainnet_api CASCADE;
CREATE SCHEMA IF NOT EXISTS vsc_mainnet_api AUTHORIZATION vsc_owner;
GRANT USAGE ON SCHEMA vsc_mainnet_api TO vsc_user;
GRANT USAGE ON SCHEMA vsc_mainnet TO vsc_user;
GRANT SELECT ON ALL TABLES IN SCHEMA vsc_mainnet_api TO vsc_user;
GRANT SELECT ON ALL TABLES IN SCHEMA vsc_mainnet TO vsc_user;
GRANT SELECT ON TABLE hafd.vsc_mainnet_accounts TO vsc_user;
GRANT SELECT ON hive.irreversible_operations_view TO vsc_user;
GRANT SELECT ON hive.irreversible_transactions_view TO vsc_user;

-- GET /
CREATE OR REPLACE FUNCTION vsc_mainnet_api.home()
RETURNS jsonb
AS
$function$
BEGIN
    RETURN (
        WITH s1 AS (SELECT * FROM vsc_mainnet.state)
        SELECT jsonb_build_object(
            'last_processed_block', s1.last_processed_block,
            'db_version', s1.db_version,
            'operations', (SELECT COUNT(*) FROM vsc_mainnet.l1_operations),
            'witnesses', (SELECT COUNT(*) FROM vsc_mainnet.witnesses)
        ) FROM s1
    );
END
$function$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_mainnet_api.get_l1_user(username VARCHAR)
RETURNS jsonb AS $$
BEGIN
    RETURN (
        SELECT jsonb_build_object(
            'name', username,
            'tx_count', COALESCE(u.count, 0),
            'last_activity', COALESCE(u.last_op_ts, '1970-01-01T00:00:00')
        )
        FROM vsc_mainnet.l1_users u
        RIGHT JOIN hafd.vsc_mainnet_accounts ac ON
            ac.id = u.id
        WHERE ac.name=username
    );
END $$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_mainnet_api.get_witness(username VARCHAR)
RETURNS jsonb AS $$
BEGIN    
    RETURN COALESCE((
        SELECT jsonb_build_object(
            'id', w.witness_id,
            'username', a.name,
            'consensus_did', w.consensus_did,
            'peer_id', w.peer_id,
            'peer_addrs', w.peer_addrs,
            'version_id', w.version_id,
            'git_commit', w.git_commit,
            'protocol_version', w.protocol_version,
            'gateway_key', w.gateway_key,
            'enabled', w.enabled,
            'last_update_ts', l1_last.ts,
            'last_update_tx', vsc_mainnet.get_tx_hash_by_op(l1_last.block_num, l1_last.trx_in_block),
            'first_seen_ts', l1_first.ts,
            'first_seen_tx', vsc_mainnet.get_tx_hash_by_op(l1_first.block_num, l1_first.trx_in_block)
        )
        FROM vsc_mainnet.witnesses w
        JOIN hafd.vsc_mainnet_accounts a ON
            a.id = w.id
        LEFT JOIN vsc_mainnet.l1_operations l1_last ON
            l1_last.id = w.last_update
        LEFT JOIN vsc_mainnet.l1_operations l1_first ON
            l1_first.id = w.first_seen
        WHERE a.name = username
    ), '{"id":null,"error":"witness does not exist"}'::jsonb);
END $$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_mainnet_api.get_op_history_by_l1_user(username VARCHAR, count INTEGER = 50, last_nonce INTEGER = NULL, bitmask_filter BIGINT = NULL)
RETURNS jsonb AS $$
BEGIN
    IF last_nonce IS NOT NULL AND last_nonce < 0 THEN
        RETURN jsonb_build_object(
            'error', 'last_nonce must be greater than or equal to 0 if not null'
        );
    ELSIF count <= 0 OR count > 1000 THEN
        RETURN jsonb_build_object(
            'error', 'count must be between 1 and 1000'
        );
    END IF;

    RETURN COALESCE((
        WITH result AS (
            SELECT o.id, a.name, o.nonce, o.block_num, o.trx_in_block, o.ts, ot.op_name, ho.body::jsonb->'value' body
            FROM vsc_mainnet.l1_operations o
            JOIN vsc_mainnet.l1_operation_types ot ON
                ot.id = o.op_type
            JOIN hafd.vsc_mainnet_accounts a ON
                a.id = o.user_id
            JOIN hive.irreversible_operations_view ho ON
                ho.id = o.op_id
            WHERE a.name = username AND
                (SELECT CASE WHEN last_nonce IS NOT NULL THEN o.nonce <= last_nonce ELSE TRUE END) AND
                (SELECT CASE WHEN bitmask_filter IS NOT NULL THEN (ot.filterer & bitmask_filter) > 0 ELSE TRUE END)
            ORDER BY o.id DESC
            LIMIT count
        )
        SELECT jsonb_agg(jsonb_build_object(
            'id', result.id,
            'username', result.name,
            'nonce', result.nonce,
            'ts', result.ts,
            'type', result.op_name,
            'l1_tx', vsc_mainnet.get_tx_hash_by_op(result.block_num, result.trx_in_block),
            'block_num', result.block_num,
            'payload', vsc_mainnet.parse_l1_payload(result.op_name, result.body)
        )) FROM result
    ), '[]'::jsonb);
END $$
LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION vsc_mainnet_api.list_latest_ops(count INTEGER = 100, bitmask_filter BIGINT = NULL, with_payload BOOLEAN = FALSE)
RETURNS jsonb AS $$
BEGIN
    IF count <= 0 OR count > 100 THEN
        RETURN jsonb_build_object(
            'error', 'count must be between 1 and 100'
        );
    END IF;

    RETURN COALESCE((
        WITH result AS (
            SELECT o.id, a.name, o.nonce, o.block_num, o.trx_in_block, o.ts, ot.op_name, ho.body::jsonb->'value' body
            FROM vsc_mainnet.l1_operations o
            JOIN vsc_mainnet.l1_operation_types ot ON
                ot.id = o.op_type
            JOIN hafd.vsc_mainnet_accounts a ON
                a.id = o.user_id
            JOIN hive.irreversible_operations_view ho ON
                ho.id = o.op_id
            WHERE (SELECT CASE WHEN bitmask_filter IS NOT NULL THEN (ot.filterer & bitmask_filter) > 0 ELSE TRUE END)
            ORDER BY o.id DESC
            LIMIT count
        )
        SELECT jsonb_agg(jsonb_build_object(
            'id', result.id,
            'username', result.name,
            'nonce', result.nonce,
            'type', result.op_name,
            'ts', result.ts,
            'l1_tx', vsc_mainnet.get_tx_hash_by_op(result.block_num, result.trx_in_block),
            'block_num', result.block_num,
            'payload', (CASE WHEN with_payload THEN vsc_mainnet.parse_l1_payload(result.op_name, result.body) ELSE NULL END)
        )) FROM result
    ), '[]'::jsonb);
END $$
LANGUAGE plpgsql STABLE;
