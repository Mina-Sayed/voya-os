# Security review: availability-block workspace

- Direct browser reads and writes of `availability_blocks` remain denied; the workspace uses narrow tenant-authorized RPCs.
- The create command permits only active owner, manager, or operations memberships, while the database repeats this test independently of the UI.
- Each successful create has an idempotency key, audit event, and outbox event in the same transaction as the source record.
- The existing trigger inserts the block into the shared exclusion-constrained occupancy ledger. A conflicting confirmed booking rejects the entire transaction.
- The workspace derives organization membership on the server and does not accept tenant identity from the form. It exposes only operational range/type/reason fields.
- This slice intentionally omits block editing, removal, overrides, approval bypass, booking confirmation, financial effects, and external notification delivery.
