# معالجة تقرير مراجعة VOYA OS — 2026-10-01

**الحالة:** Working-tree candidate — verified on this checkout only.
**التقرير:** `VOYA_OS_Code_Review_2026-09-29_AR.md` (مراجعة `develop@8589a93` و`PR #76@b82eb46`).
**PR:** [#77 إلى `main`](https://github.com/Mina-Sayed/voya-os/pull/77)، على الفرع `fix/code-review-remediation-pr`.
**الفرع الأساسي للعمل:** `e3f194e7d9ca0ad8331877a4321a3d08f595ad4d`، مع الحفاظ على النسخة المحلية المنقولة إلى worktree منفصل.

| ID | النتيجة | دليل الإغلاق في checkout |
|---|---|---|
| R01 | أُصلحت | حراس AAL2 على 72 توقيعًا بشريًا؛ استثناء قبول الدعوة قبل workspace يبقى AAL1. `workspace_rpc_aal2_closure.sql` و`workspace_rpc_aal2_extended_closure.sql`. |
| R02 | أُصلحت | نطاق إسناد الليد يُفحص بعد القفل وقبل replay أو التحويل. `crm_assignment_idempotency_remediation.sql`. |
| R03 | أُصلحت | التأكيد الجزئي يحفظ المفاتيح والمعرفات وتقدم الصور، ويستعيد فترة الملكية والصور المسجلة. `actions.phase1.test.ts` و`whatsapp_confirmation_recovery.sql`. |
| R04 | أُصلحت | نتيجة رسالة أقدم ترجع `stale` ولا ترجع الحالة أو المؤشر إلى الخلف. `whatsapp_ai_result_ordering.sql`. |
| R05 | أُصلحت | قبول دعوة قديمة لا يبدل دور عضوية نشطة؛ إثبات آخر مالك وقيود القفل في `code_review_r05_r18_membership_guards.sql`. |
| R06 | أُصلحت | مفتاح حدث الإقامة مرتبط بالحجز والنوع والملاحظات بعد التطبيع؛ الاختلاف يرفض بـ23505. `booking_stay_idempotency.sql`. |
| R07 | أُصلحت | مفتاح إنشاء المسودة يبقى على الحجز، وexact replay يعيد نفس السجل بعد الاعتماد والتأكيد والمغادرة. `booking_draft_idempotency_lifecycle.sql`. |
| R08 | أُصلحت | مفتاح التأكيد مرتبط بالحجز وhash للطلب؛ replay المطابق ينجح والحجز الثاني يرفض قبل التغيير. `booking_confirm_idempotency.sql`. |
| R09 | أُصلحت | مسار الصورة مشتق من مفتاح المحاولة، وretry يتحقق من بايتات الكائن الموجود ويحافظ عليه بعد غموض نتيجة RPC. `properties/actions.test.ts`. |
| R10 | أُصلحت | قراءة recovery تعرض اعتماد الحجز المنتهي وتسمح بطلب اعتماد جديد للأدوار المصرح بها. `bookings-page.test.tsx` و`approval_work_queue_recovery.sql`. |
| R11 | أُصلحت | إنهاء AI run وdead-letter للـoutbox يحدثان ذريًا تحت lease. `failure-terminalization.test.ts` و`outbox_failure_terminalization.sql`. |
| R12 | أُصلحت | حالة رسالة WhatsApp أو دعوة Resend تنتهي ذريًا مع outbox؛ الفشل المؤقت يبقي التسليم queued. `failure-terminalization.test.ts` و`outbox_failure_terminalization.sql`. |
| R13 | أُصلحت | فورم تعديل الليد يرسل الإسناد الحالي؛ حفظ حقول أخرى لا يمحوه. `leads-page.test.tsx`. |
| R14 | أُصلحت | activity والمتابعات تستخدم المنطقة الزمنية للمؤسسة صراحة، بما فيها الشتاء والصيف. `leads-page.test.tsx` تحت `TZ=UTC`. |
| R15 | أُصلحت | لوحة المتابعة تجلب pending فقط، والعداد يحسب قبل حد العرض. `live-dashboard-data.test.ts` و`approval_work_queue_recovery.sql`. |
| R16 | أُصلحت | مفاتيح CRM تحفظ SHA-256 لبيانات الأمر؛ replay مختلف يرفض وحقول legacy القابلة للاستعادة تُملأ. `crm_assignment_idempotency_remediation.sql`. |
| R17 | أُغلقت سابقًا في التعديل المحلي وأُدرج إصلاحها | CSP يسمح بأصل Supabase المحدد للصور، واختبارات `content-security-policy.test.ts` تمر. |
| R18 | أُصلحت | المؤسسة الجديدة متاحة فقط لمن لا يملك أي سجل عضوية؛ صفحة onboarding والـAction وRPC متوافقة. `code_review_r05_r18_membership_guards.sql` واختبارات onboarding. |
| R19 | أُصلحت | أزرار النقل تتبع صلاحية التشغيل التي يستخدمها الـAction. `transport-operations-page.test.tsx`. |
| Readiness (ملاحظة بلا ID) | أُصلحت | `service_role` يحصل على SELECT فقط على `organizations` المطلوب لفحص الجاهزية. `readiness_organizations_grant.sql` واختبار route الحالي. |

## التحقق

- `npm test` على فرع PR النظيف المبني على `origin/main`: 146 ملفًا، 724 اختبارًا ناجحًا.
- `npm run lint`: ناجح.
- `npm run typecheck`: ناجح.
- `deno check --no-lock supabase/functions/outbox-dispatch/index.ts`: ناجح على فرع PR النظيف.
- `VOYA_DB_TEST=1 DATABASE_URL=postgresql://postgres@127.0.0.1:55493/voya_code_review_r05_r18_test npm run test:db`: ناجح على قاعدة محلية مؤقتة `*_test`.
- اختبارات regression الجديدة أُجريت حمراء على السلوك السابق ثم خضراء بعد التعديل؛ قاعدة البيانات أعيد بناؤها عبر سلسلة migrations كاملة.

## الحدود المتبقية

- هذا إثبات **Verified — checkout**. لا يثبت تطبيق migrations أو grants في Supabase مُدار أو Vercel؛ حالتهما **Unknown** لهذا العمل.
- لم تُفعّل ردود WhatsApp/AI الآلية، ولم تتغير Production أو أي خدمة مُدارة.
- انتهاء عملية Node قبل حفظ نتيجة فشل التأكيد الجزئي يترك claim قائمًا حتى انتهاء lease البالغ 30 دقيقة؛ أعطال الرفع/التنزيل التي تعيد خطأً صريحًا تستعيد الآن المحاولة بأمان.
