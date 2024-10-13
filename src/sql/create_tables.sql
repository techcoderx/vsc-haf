SET ROLE vsc_owner;
CREATE SCHEMA IF NOT EXISTS vsc_app;

CREATE TABLE IF NOT EXISTS vsc_app.l1_operation_types(
    id SERIAL PRIMARY KEY,
    op_name VARCHAR(25),
    filterer BIGINT GENERATED ALWAYS AS (2^(id-1)) STORED
);

CREATE TABLE IF NOT EXISTS vsc_app.l1_operations(
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

CREATE TABLE IF NOT EXISTS vsc_app.l1_users(
    id INTEGER PRIMARY KEY,
    count BIGINT DEFAULT 0,
    last_op_ts TIMESTAMP
);

CREATE TABLE IF NOT EXISTS vsc_app.l1_txs(
    id BIGINT PRIMARY KEY, -- id from l1_operations table
    details BIGINT NOT NULL -- id from contract_calls table
);

CREATE TABLE IF NOT EXISTS vsc_app.l1_tx_multiauth(
    id BIGINT PRIMARY KEY, -- id from l1_txs table
    user_id INTEGER NOT NULL, -- id from accounts state provider table
    auth_type SMALLINT NOT NULL -- 1 for active auth, 2 for posting auth
);

CREATE TABLE IF NOT EXISTS vsc_app.l2_txs(
    id SERIAL PRIMARY KEY,
    cid VARCHAR(59) NOT NULL, -- call_contract transaction CID
    block_num INTEGER NOT NULL, -- included in l2 block number from blocks table
    idx_in_block SMALLINT NOT NULL, -- position in l2 block, max 32767
    tx_type SMALLINT NOT NULL, -- 1 for call_contract, 2 for contract_output, 3 for transfer, 4 for withdraw
    nonce INTEGER, -- currently not enforced
    details BIGINT, -- transaction details from contract_calls/transfers table. this should not be fk
    UNIQUE(cid)
);

CREATE TABLE IF NOT EXISTS vsc_app.l2_tx_multiauth(
    id INTEGER PRIMARY KEY, -- id from l2_txs table
    did INTEGER NOT NULL -- id from dids table
);

CREATE TABLE IF NOT EXISTS vsc_app.l2_tx_events(
    event_id INTEGER NOT NULL, -- id from events table
    l2_tx_id INTEGER NOT NULL, -- id from l2_txs table
    tx_pos INTEGER NOT NULL,
    evt_pos SMALLINT NOT NULL, -- assume each tx can never emit more than 32767 events
    evt_type INTEGER NOT NULL,
    token SMALLINT NOT NULL, -- 0 for HIVE, 1 for HBD
    amount INTEGER NOT NULL,
    memo VARCHAR,
    owner_name VARCHAR NOT NULL,
    PRIMARY KEY(event_id, l2_tx_id, tx_pos, evt_pos)
);

CREATE TABLE IF NOT EXISTS vsc_app.l2_blocks(
    id INTEGER PRIMARY KEY,
    proposed_in_op BIGINT NOT NULL,
    block_hash VARCHAR(59) NOT NULL,
    block_header_hash VARCHAR(59) NOT NULL,
    proposer INTEGER NOT NULL,
    br_start INTEGER NOT NULL,
    br_end INTEGER NOT NULL,
    merkle_root BYTEA NOT NULL,
    voted_weight INTEGER NOT NULL,
    sig BYTEA NOT NULL,
    bv BYTEA NOT NULL
);

CREATE TABLE IF NOT EXISTS vsc_app.contract_calls(
    id BIGSERIAL PRIMARY KEY,
    contract_id VARCHAR(68) NOT NULL,
    contract_action VARCHAR NOT NULL,
    payload jsonb NOT NULL,
    io_gas INTEGER,
    contract_output_tx_id VARCHAR(59),
    contract_output jsonb
);

CREATE TABLE IF NOT EXISTS vsc_app.contract_outputs(
    id VARCHAR(59) PRIMARY KEY,
    block_num INTEGER NOT NULL,
    idx_in_block SMALLINT NOT NULL,
    contract_id VARCHAR(68) NOT NULL,
    total_io_gas INTEGER
);

CREATE TABLE IF NOT EXISTS vsc_app.transfers(
    id BIGSERIAL PRIMARY KEY,
    from_acctype SMALLINT NOT NULL, -- from account type, 1 for hive, 2 for did
    from_id INTEGER NOT NULL, -- from account id referencing dids/hive.vsc_app_accounts table
    to_acctype SMALLINT NOT NULL, -- to account type, 1 for hive, 2 for did
    to_id INTEGER NOT NULL, -- to account id referencing dids/hive.vsc_app_accounts table
    amount INTEGER NOT NULL, -- amount in mHIVE/mHBD
    coin SMALLINT NOT NULL, -- 0 for HIVE, 1 for HBD
    memo VARCHAR
);

CREATE TABLE IF NOT EXISTS vsc_app.events(
    id SERIAL PRIMARY KEY,
    cid VARCHAR(59) NOT NULL,
    block_num INTEGER NOT NULL,
    idx_in_block SMALLINT NOT NULL,
    UNIQUE(cid)
);

CREATE TABLE IF NOT EXISTS vsc_app.contracts(
    contract_id VARCHAR(68) PRIMARY KEY,
    created_in_op BIGINT NOT NULL,
    last_updated_in_op BIGINT,
    name VARCHAR,
    description VARCHAR,
    code VARCHAR(59) NOT NULL,
    proof_hash VARCHAR(59),
    proof_sig BYTEA,
    proof_bv BYTEA
);

CREATE TABLE IF NOT EXISTS vsc_app.witnesses(
    id INTEGER PRIMARY KEY, -- hive user id
    witness_id SERIAL, -- sequential vsc witness id
    did VARCHAR NOT NULL,
    consensus_did VARCHAR,
    sk_posting VARCHAR(53),
    sk_active VARCHAR(53),
    sk_owner VARCHAR(53),
    enabled BOOLEAN DEFAULT FALSE,
    enabled_at BIGINT,
    disabled_at BIGINT,
    first_seen BIGINT NOT NULL,
    git_commit VARCHAR(40),
    last_block INTEGER,
    produced INTEGER DEFAULT 0,
    last_toggle_archive INTEGER NOT NULL,
    last_keyauth_archive INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS vsc_app.witness_toggle_archive(
    id SERIAL PRIMARY KEY,
    witness_id INTEGER NOT NULL, -- hive user id, not vsc witness id
    op_id BIGINT NOT NULL,
    last_updated BIGINT NOT NULL,
    enabled BOOLEAN NOT NULL
);

CREATE TABLE IF NOT EXISTS vsc_app.keyauths_archive(
    id SERIAL PRIMARY KEY,
    user_id INTEGER NOT NULL,
    op_id BIGINT NOT NULL,
    last_updated BIGINT NOT NULL,
    node_did VARCHAR,
    consensus_did VARCHAR,
    sk_posting VARCHAR(53),
    sk_active VARCHAR(53),
    sk_owner VARCHAR(53)
);

CREATE TABLE IF NOT EXISTS vsc_app.election_results(
    epoch INTEGER PRIMARY KEY,
    proposed_in_op BIGINT NOT NULL,
    proposer INTEGER NOT NULL,
    data_cid VARCHAR(59) NOT NULL,
    voted_weight INTEGER NOT NULL, -- aggregated vote weight for the election result
    weight_total INTEGER NOT NULL, -- new(!) total weight eligible for the next epoch and blocks
    sig BYTEA NOT NULL,
    bv BYTEA NOT NULL
);

CREATE TABLE IF NOT EXISTS vsc_app.election_result_members(
    id SERIAL PRIMARY KEY,
    epoch INTEGER NOT NULL,
    witness_id INTEGER NOT NULL, -- hive user id, not vsc witness id
    consensus_did VARCHAR(78) NOT NULL,
    weight INTEGER DEFAULT 1,
    idx SMALLINT NOT NULL,
    UNIQUE(epoch, witness_id)
);

CREATE TABLE IF NOT EXISTS vsc_app.vsc_node_git(
    id INTEGER PRIMARY KEY,
    git_commit VARCHAR(40)
);

CREATE TABLE IF NOT EXISTS vsc_app.state(
    id SERIAL PRIMARY KEY,
    last_processed_block INTEGER NOT NULL DEFAULT 0,
    db_version INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS vsc_app.subindexer_state(
    id SERIAL PRIMARY KEY,
    last_processed_op BIGINT NOT NULL DEFAULT 0,
    l2_head_block INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS vsc_app.anchor_refs(
    id SERIAL PRIMARY KEY,
    cid VARCHAR(59) NOT NULL, -- call_contract transaction CID
    block_num INTEGER NOT NULL, -- included in l2 block number from blocks table
    idx_in_block SMALLINT NOT NULL,
    tx_root BYTEA NOT NULL
);

CREATE TABLE IF NOT EXISTS vsc_app.anchor_ref_txs(
    ref_id INTEGER,
    tx_id BYTEA,
    idx_in_ref INTEGER NOT NULL,
    PRIMARY KEY(ref_id, tx_id)  
);

CREATE TABLE IF NOT EXISTS vsc_app.multisig_txrefs(
    id SERIAL PRIMARY KEY,
    in_op BIGINT NOT NULL,
    ref_id VARCHAR(59) NOT NULL
);

CREATE TABLE IF NOT EXISTS vsc_app.deposits_to_hive(
    id SERIAL PRIMARY KEY,
    in_op BIGINT NOT NULL,
    amount INTEGER NOT NULL,
    asset SMALLINT NOT NULL,
    dest_acc INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS vsc_app.deposits_to_did(
    id SERIAL PRIMARY KEY,
    in_op BIGINT NOT NULL,
    amount INTEGER NOT NULL,
    asset SMALLINT NOT NULL,
    dest_did INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS vsc_app.withdrawal_request(
    id SERIAL PRIMARY KEY,
    in_op BIGINT NOT NULL,
    amount INTEGER NOT NULL,
    amount2 INTEGER NOT NULL,
    asset SMALLINT NOT NULL,
    dest_acc INTEGER NOT NULL,
    status SMALLINT DEFAULT 1,
    UNIQUE(in_op)
);

CREATE TABLE IF NOT EXISTS vsc_app.withdrawal_status(
    id SERIAL PRIMARY KEY,
    name VARCHAR(10)
);

CREATE TABLE IF NOT EXISTS vsc_app.withdrawals(
    id SERIAL PRIMARY KEY,
    in_op BIGINT NOT NULL,
    amount INTEGER NOT NULL,
    asset SMALLINT NOT NULL,
    dest_acc INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS vsc_app.l2_withdrawals(
    id BIGSERIAL PRIMARY KEY,
    from_acctype SMALLINT NOT NULL, -- from account type, 1 for hive, 2 for did
    from_id INTEGER NOT NULL, -- from account id referencing dids/hive.vsc_app_accounts table
    to_id INTEGER NOT NULL, -- to account id referencing dids/hive.vsc_app_accounts table
    amount INTEGER NOT NULL, -- amount in mHIVE/mHBD
    asset SMALLINT NOT NULL, -- 0 for HIVE, 1 for HBD
    memo VARCHAR
);

CREATE TABLE IF NOT EXISTS vsc_app.dids(
    id SERIAL PRIMARY KEY,
    did VARCHAR(78) NOT NULL,
    UNIQUE(did)
);

CREATE TABLE IF NOT EXISTS vsc_app.bls_dids(
    id SERIAL PRIMARY KEY,
    bls_did VARCHAR(78) NOT NULL,
    UNIQUE(bls_did)
);