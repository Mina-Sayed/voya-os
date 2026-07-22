# Security review: in-app notification foundation

- Logical notifications are tenant- and recipient-membership scoped with dedupe keys; direct browser table reads and updates are denied.
- `list_my_notifications` derives the active recipient from `auth.uid()` and returns that recipient's records only.
- `mark_notification_read` verifies the same membership and notification ownership, is naturally idempotent, and emits one audit fact only on the first state transition.
- The UI exposes no cross-member view, export, provider delivery, or external channel.
- Notification creation is intentionally not browser-callable. A future trusted domain/outbox worker must apply template, field-redaction, retention, and provider policy before it creates logical notifications or delivery attempts.
