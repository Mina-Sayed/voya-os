# Security Review: Property Creation Command

Date: 2026-07-22

`create_property` permits only active owner, manager, or operations members to
create an active property in their derived organization. Browser table inserts
remain denied. The command validates required data, detects idempotency-key
reuse, and writes property, audit event, and `property.created` outbox event in
one transaction. Pricing, address, owner assignment, availability blocks, and
booking effects are intentionally separate commands.
