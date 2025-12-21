SET ROLE magi_owner;
CREATE SCHEMA IF NOT EXISTS magi_app;

CREATE TABLE IF NOT EXISTS magi_app.l1_operation_types(
    id SERIAL PRIMARY KEY,
    op_name VARCHAR(30) NOT NULL,
    filterer BIGINT GENERATED ALWAYS AS (2^(id-1)) STORED,
    UNIQUE(op_name)
);

CREATE TABLE IF NOT EXISTS magi_app.l1_operations(
    id BIGSERIAL PRIMARY KEY,
    user_id INTEGER NOT NULL,
    nonce INTEGER NOT NULL,
    op_id BIGINT NOT NULL,
    block_num INTEGER NOT NULL, -- TODO replace op_id reference with these 3 columns
    trx_in_block SMALLINT NOT NULL,
    op_pos INTEGER NOT NULL,
    op_type INTEGER NOT NULL,
    ts TIMESTAMP NOT NULL,
    UNIQUE(block_num, trx_in_block, op_pos)
);

CREATE TABLE IF NOT EXISTS magi_app.l1_users(
    id INTEGER PRIMARY KEY,
    count BIGINT DEFAULT 0,
    last_op_ts TIMESTAMP
);

CREATE TABLE IF NOT EXISTS magi_app.witnesses(
    id INTEGER PRIMARY KEY, -- hive user id
    witness_id SERIAL, -- sequential vsc witness id
    consensus_did VARCHAR,
    peer_id VARCHAR,
    peer_addrs jsonb,
    version_id VARCHAR,
    git_commit VARCHAR(40),
    protocol_version SMALLINT,
    gateway_key VARCHAR,
    enabled BOOLEAN DEFAULT FALSE,
    last_update BIGINT NOT NULL, -- from l1_operations
    first_seen BIGINT NOT NULL -- from l1_operations
);

CREATE TABLE IF NOT EXISTS magi_app.state(
    id SERIAL PRIMARY KEY,
    last_processed_block INTEGER NOT NULL DEFAULT 0,
    db_version INTEGER NOT NULL DEFAULT 1
);
