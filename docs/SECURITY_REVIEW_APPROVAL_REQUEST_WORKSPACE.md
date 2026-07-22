# Security review: approval-request workspace

- Direct browser reads of `approval_requests` remain denied. The read RPC has a fixed search path, validates a bounded limit, and returns no proposal snapshot, snapshot hash, requester identity, or decisions.
- owner and manager read tenant-scoped request metadata; sales, operations, and accountant read only requests they created. Viewer and suspended memberships are denied.
- The UI is read-only: it has no approve, reject, cancel, or execute control.
- This feature intentionally does not encode policy thresholds, approver eligibility, MFA/recent-auth requirements, decision lifecycle, expiry execution, or single-use consumption. Those require an approved policy and dedicated command tests.
