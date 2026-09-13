# Voya OS — مراجعة الجاهزية التقنية والتشغيلية

تاريخ المراجعة: **2026-09-05**. القرار: **NO-GO لإطلاق عملاء حقيقيين بالحالة الحالية**. مناسب لاستكمال QA داخلي ببيانات صناعية، ثم تجربة محدودة بعد إغلاق موانع الأمان وصحة الحجز وتوحيد النسخة المنشورة.

هذه مراجعة للكود والفلو وحدود الأمان والـPRs والأدلة التشغيلية المتاحة، وليست شهادة خلو من الثغرات أو اختبار اختراق شامل. لم يتم تعديل التطبيق أو دمج PR أو نشر نسخة أو تغيير أي مزود مُدار. تجارب الكتابة تمت على قاعدة محلية منفصلة باسم `voya_cto_20260905_test`؛ تجارب إثبات العيوب انتهت بـ`ROLLBACK`.

**نطاق الأدلة**

- **Verified — checkout:** `main` و`origin/main` عند `4ab9b839e9ff30bf75471768671fc1157edc0f34`، والعمل الأصلي كان نظيفًا عند البداية. 72 migration. تم تتبع المصادقة والصلاحيات، الحجز والموافقات، العرض النقدي، CRM والعقارات، المهام والنقل، WhatsApp/AI/outbox، CI وواجهات الصحة. المراجعة التفصيلية ركزت على مسارات الثقة والمنطق الحرج؛ الاختبارات تغطي نطاقًا أوسع من القراءة اليدوية.
- **Branch-only:** `origin/develop` عند `740507bafac6da74d4982961ddd22a09d80595ec`. الفرق عن `main` هو تقوية idempotency للأسطول واختباراتها ومعالجة numeric overflow، في 9 ملفات. لم يتم دمجه أو اعتباره منشورًا.
- **Verified — GitHub:** جرد جميع الـ10 PRs المفتوحة، حالتها وملفاتها وتغييراتها الأساسية وأسباب فشل الـCI المتاحة. فحص PR لا يعني أن كل سطر في كل فرع خضع لتحليل مستقل أو إعادة تشغيل كاملة محليًا.
- **Verified — managed Supabase:** قراءة مشروع `voya-os-staging`، المرجع `tvgarlsgtgrabtdovgvz`؛ وملاحظة حالة المشروع القديم `nseeteviretfabdfrgrc` من قائمة المشاريع فقط.
- **Verified — managed Vercel:** قراءة المشروع `prj_9eg8OuaIL3hthyNcTqzNHMMLaJka` وآخر deployment وaliases، مع GET عامة للصحة والإصدار وتسجيل الدخول.

**الموانع مرتبة بالأولوية**

| ID | الأولوية | المشكلة | الدليل والأثر | المطلوب للإغلاق |
|---|---|---|---|---|
| R-01 | P1 | MFA غير مفروض على كل مداخل قاعدة البيانات | جلسة `authenticated` مع `aal1` قرأت 4 عقارات وأنشأت عقارًا في مؤسسة صاحب الجلسة محليًا. الواجهة تمنع ذلك، لكن `list_properties_v1` و`create_property_v1` تتحققان من العضوية دون AAL2. تعريفات وصلاحيات مماثلة موجودة على Staging. ليست قراءة عابرة للمؤسسات؛ هي تجاوز العامل الثاني. | فرض AAL2 على جميع RPCs وقراءات RLS التجارية المعرضة، مع استثناءات onboarding/invitation موثقة واختبارات رفض AAL1 مستقلة. |
| R-02 | P1 | أوامر الحجز القديمة تتجاوز الفلو التجاري | تجربة كاملة محلية: sales_agent ينشئ مسودة قديمة، يطلب موافقة، عضو owner آخر يعتمد، ثم sales_agent يؤكد الحجز. النتيجة `confirmed` مع مبلغ وعملة NULL و`needs_completion`. صلاحيات تنفيذ الأوامر القديمة موجودة أيضًا على Staging. الفصل بين مقدم الطلب والموافق ظل قائمًا؛ التجاوز يخص شروط السعر وصلاحية التأكيد التجاري. | إغلاق مداخل الكتابة القديمة أو جعلها تفوض إلى نفس القواعد التجارية؛ الحفاظ على قراءة السجلات التاريخية. اختبار كل overload وكل role. |
| R-03 | P1 / مانع دمج | PR #25 يضيف قراءة لا تتحقق من المؤسسة المسموحة | دوال `count_*` ذات `SECURITY DEFINER` تعتمد على `p_organization_id` فقط. أثبت تطبيق قسم الإحصاءات وحده داخل transaction محلية أن مستخدم A يقرأ عدد عقارات B، وأن `anon` يملك EXECUTE عبر PUBLIC. دوال القائمة الجديدة تعرض النمط الخطر نفسه في المصدر. هذا **Branch-only**، وليس ثغرة مثبتة في main أو Staging الحالية. | منع دمجه حتى إضافة تحقق العضوية/الدور/AAL2 وإلغاء PUBLIC/anon grants واختبارات المؤسسات؛ تدقيق القوائم والـbatch RPCs أيضًا. |
| R-04 | P1 | وحدة المبلغ غير متسقة بين الإدخال والتخزين والعرض | نموذج الإنشاء يسمي الحقل «المبلغ المتفق عليه» ويرسل النص مباشرة إلى `p_amount_minor`. بطاقة الحجز والموافقات تعرض integer الخام بجانب EGP. إدخال 2500 بمعنى جنيه يخزن 2500 وحدة صغرى؛ وقيمة مخزنة 250000 تظهر كأنها 250000 EGP. الحفاظ على bigint لا يعالج وحدات العملة. | تحويل decimal string إلى minor units والعكس بطريقة دقيقة ومحددة للعملة، مع أمثلة UI واختبارات الإنشاء والتعديل والموافقة والعرض. لا اختراع سياسة تسعير أو تحصيل. |
| R-05 | P1 قبل تفعيل AI الحي | إيقاف WhatsApp AI لا يُعاد فحصه في حدود التنفيذ، وlow confidence يسمح برد آلي | `renew_whatsapp_ai_event_lease_v1` و`start_whatsapp_ai_run_v1` لا تتحققان من channel kill switch. helper `shouldSendWhatsappReply` لا يمنع confidence=low، وتطبيق النتيجة لا يفرض المنع. تأكدت التعريفات الحالية والـhelper المنشور على Staging. يتطلب أثر الإرسال أن تكون أعلام المزود مفعلة؛ لم أتحقق من قيمها ولم أرسل رسائل. | إصلاح #24 واستكمال SQL behavioral tests لتعطيل القناة بين enqueue والتنفيذ/التجديد/تطبيق النتيجة؛ تأكيد رفض low-confidence وعدم إبقاء primitive يسمح بتجاوز الحماية للعامل نفسه. |
| R-06 | P1 / إصدار | النسخة المنشورة لا تطابق النسخة المختبرة | آخر Production ظاهر في Vercel هو `dpl_EbZTNcEw62YcYPf5uBCaMvpHsmB3`، source=`cli`، ref=`codex/release-20260811`، SHA=`374764db…`، `gitDirty=1`. المشروع القديم في Supabase `INACTIVE`؛ Staging الجديدة `ACTIVE_HEALTHY`. `/api/health` يرجع 200 لكن `/api/health/ready` و`/api/version` يرجعان 404 على alias الإنتاج. لا يوجد إثبات أن التطبيق المنشور يستخدم Staging الجديدة. | Artifact من commit نظيف ومعروف، مطابقة DB/Storage/functions/grants، توثيق target Supabase، واختبار readiness وversion والفلو على نفس المرشح قبل الترقية. |
| R-07 | P1 لفلو النقل | وقت النقل يعتمد على timezone السيرفر | UI ترسل `datetime-local` بلا offset؛ `parseIsoDateTime` يستخدم `new Date(value).toISOString()` في السيرفر. نفس `2026-09-05T12:00` أصبح `12:00Z` مع TZ=UTC و`09:00Z` مع TZ=Africa/Cairo. خطر تحريك الرحلة ساعات في بيئة مختلفة. | تعريف توقيت المؤسسة/المكان وتحويله صراحة، مع اختبارات اختلاف TZ وDST، وإظهار المنطقة الزمنية للمشغل. |
| R-08 | P2 / اكتمال فلو | إلغاء الحجز غير متاح end-to-end على main | تعديل الحجز وقرارات amend/cancel موجودة بالفعل؛ الناقص هو actions/controls لطلب الإلغاء وتنفيذه وإلغاء المسودة. #27 يغطي هذه الفجوة ويضيف replay guards وربط approval ID، لكنه متعارض مع develop. | حل التعارض، إعادة الـCI على ناتج الدمج، واختبار متصفح حقيقي لدورة الإلغاء وإطلاق الإشغال؛ تبقى الآثار المالية للإلغاء قرار منتج منفصلًا. |
| R-09 | P2 / دفاع إضافي | Staging تحمل DML grants زائدة مقارنةً بالـcheckout | `authenticated` لديه INSERT/UPDATE/DELETE على 7 جداول: properties/bookings/organizations/organization_memberships/clients/property_images/property_v1_command_idempotency. الـcheckout المحلي ينفيها جميعًا. RLS وFORCE RLS موجودان، والسياسات الحالية SELECT-only أو لا توجد سياسات؛ لذلك هذا **ليس إثبات قدرة على كتابة مباشرة**، لكنه drift حقيقي وفقدان طبقة منع. | مطابقة grants واختبارات الاستحقاقات مع migrations، وفحص طريقة تطبيق SQL بدل الاكتفاء بعدد الملفات. |
| R-10 | P2 / تشغيل | نشر العامل لا يثبت التسليم المستمر والتعافي | outbox-dispatch موجود ACTIVE v1 على Staging. لا pg_cron ولا pg_net ولا cron.job في القاعدة؛ scheduler خارجي محتمل لكنه غير متحقق. أسرار التشغيل وأعلام المزود والتسليم/التكرار/الـdead-letter والنسخ والاستعادة والإنذارات غير مثبتة. | إثبات worker schedule، retry/dead-letter، delivery acknowledgements، مراقبة queue age، وتجربة استعادة محددة RPO/RTO قبل إطلاق نطاق يعتمد عليها. |
| R-11 | P2 / توسع | حسابات dashboard مبنية على تحميل القوائم | dashboard يحسب مؤشرات من arrays ويقرأ آخر 50 approval؛ لا يضمن العدد الإجمالي للطلبات المعلقة خارج النافذة. قوائم العقارات/العملاء غير مقسمة في التطبيق؛ لا توجد قياسات تحميل ممثلة للتوسع في هذه المراجعة. #25 يحاول العلاج لكنه يصنع arrays وهمية بحجم العدادات ويعرض recent leads كعدد إجمالي. | aggregates آمنة ومؤشرات مستقلة عن pagination، صفحات قوائم وبحث محدود، ثم قياس workload متفق عليه. |

**مراجع كود للموانع**

- R-01: [property RPCs](../supabase/migrations/20260813000100_property_inventory_v1.sql)، وبالأخص create عند السطر 147 وlist عند 239 وgrants عند 991؛ [workspace gate](../src/features/auth/require-workspace-membership.ts). اختبارات AI AAL2 الموجودة تثبت شريحة AI فقط، ولا تثبت حماية جميع RPCs.
- R-02: [legacy draft](../supabase/migrations/20260722000500_booking_draft_command.sql)، [legacy request/confirm](../supabase/migrations/20260803085546_production_security_remediation.sql)، [commercial lifecycle](../supabase/migrations/20260812015419_commercial_booking_v1.sql).
- R-03: [PR #25 migration عند SHA المراجع](https://github.com/Mina-Sayed/voya-os/blob/c5b241ed1a2a126c8bbbd10dadac63c36a6f6496/supabase/migrations/20260831000100_performance_optimization.sql#L11). الإثبات المحلي اختبر قسم العدادات الستة، ولم يطبق migration كاملة أو ينشرها.
- R-04: [draft form](../src/features/bookings/booking-draft-form.tsx)، [booking action](../src/app/workspace/bookings/actions.ts)، [booking card](../src/features/bookings/bookings-page.tsx)، [approval amount](../src/features/approvals/approval-requests-page.tsx).
- R-05: [WhatsApp migration](../supabase/migrations/20260827153809_whatsapp_ai_agent_phase1.sql)، [reply helper](../src/lib/whatsapp/whatsapp-ai-worker.ts)، [worker](../supabase/functions/outbox-dispatch/index.ts). `verify_jwt=false` في Edge Function ليس ثغرة منفردة: العامل يطبق bearer secret الخاص به عبر `authorizeOutboxWorkerRequest`.
- R-07: [time parser](../src/domain/time/iso-datetime.ts)، [transport action](../src/app/workspace/transport/actions.ts)، [transport form](../src/features/transport/transport-operations-page.tsx).
- R-11: [live dashboard](../src/features/dashboard/live-dashboard-data.ts).

**حكم كل PR مفتوحة**

اللون الأخضر وصف لنتيجة check عند head معين، وليس اعتمادًا هندسيًا لناتج دمج جديد. لم يتم نشر reviews/comments على GitHub.

| PR / head | الحالة عند الفحص | الحكم |
|---|---|---|
| [#29 — CI hygiene](https://github.com/Mina-Sayed/voya-os/pull/29) / `ab639ae` | CLEAN، checks خضراء | أفضل مرشح دمج منخفض المخاطرة بعد إجراءات الريبو. غياب Snyk token يفشل verify صراحةً؛ لا يحوّل scanner غير المشغل إلى PASS. لا يعالج موانع المنتج والأمان أعلاه. |
| [#27 — cancellation wiring](https://github.com/Mina-Sayed/voya-os/pull/27) / `f9aabe3` | CI أخضر، CONFLICTING | مهم لإكمال الفلو؛ حل التعارض وإعادة الفحص. الوصف «wiring فقط» لا يعكس إضافة migrations كبيرة لـreplay وربط approval. الذاكرة في الفرع ما زالت تصف projection الإلغاء كأنه غير منفذ رغم وجود migration أحدث فيه. |
| [#26 — rate-limit repair](https://github.com/Mina-Sayed/voya-os/pull/26) / `063e4b5` | Draft، CONFLICTING؛ verify ناجح وGitGuardian فاشل | GitGuardian يعرض «2 secrets uncovered!». لم أفترض أنها أسرار حقيقية ولم أطبع قيمًا؛ يلزم triage. أصل المخالفة القديمة ليس قائمًا على Staging الحالية: overload ذو 4 args غائب وذو 2 args service-role-only. قيّم الحاجة الفعلية للإصلاح لكل target بدل دمجه كعلاج لمشكلة مغلقة على هذه البيئة. |
| [#25 — performance/auth](https://github.com/Mina-Sayed/voya-os/pull/25) / `c5b241e` | verify فاشل في TypeScript، REVIEW_REQUIRED | **منع دمج** بسبب R-03. اختبارات counters تعرف data كـarray ثم تعطيها number. إضافة bypass للـrate-limit خارج production توسع غير لازم. فصل إصلاحات الأداء عن auth وإعادة تصميم حدود القراءة. |
| [#24 — WhatsApp safety](https://github.com/Mina-Sayed/voya-os/pull/24) / `12f8127` | Draft، verify فاشل | المشكلة المستهدفة مهمة وموجودة. الفشل الحالي عند guard العدد المتوقع للمigrations؛ يجب تحديث harness، إضافة اختبارات سلوك لا مجرد البحث عن نص في function definition، وعدم ربط هذا الإصلاح بتوقع auth غير متوافق. |
| [#23 — validation clarity](https://github.com/Mina-Sayed/voya-os/pull/23) / `42de31e` | BEHIND، MERGEABLE، checks خضراء | تغييرات محدودة تستحق التحديث وإعادة الفحص. لا تصلح وحدات العملة أو timezone؛ بعض رسائل UX تكشف تفاصيل داخلية مثل idempotency وأسماء enum. |
| [#15 — WebMCP](https://github.com/Mina-Sayed/voya-os/pull/15) / `fe36ec0` | CONFLICTING، CHANGES_REQUESTED، verify فاشل | يؤجل بعد استقرار المصدر التجاري. فشل Snyk المسجل يخص next@16.2.12 في ذلك الفرع، بينما main الحالية 16.3.3. لا يعمم على main. تحقق availability يستخدم قائمة عمل وليست query تعارض مخصصة؛ يلزم مراجعة اكتمال النتائج قبل اعتباره ضمان توفر. |
| [#14 — booking hardening](https://github.com/Mina-Sayed/voya-os/pull/14) / `e9cd876` | Draft، CONFLICTING، verify فاشل | اتجاهه يعالج R-02/R-04، لكن استخراج الأجزاء المطلوبة على baseline الحالي أو إعادة بناء الفرع أفضل من دمج واسع كما هو. الفشل `permission denied for function confirm_booking` في اختبار concurrency قديم بعد revocation، وليس إثبات فشل منع ازدواج الحجز. |
| [#11 — reset E2E](https://github.com/Mina-Sayed/voya-os/pull/11) / `6dbe042` | BEHIND، checks خضراء | لا يدمج كما هو: ينادي script غير موجود `npm run db:reset` ثم يخفي الخطأ بـ`|| true`، ويفحص port 5432 بينما harness المصادقة يستخدم مشروعًا مستقلًا عند 55322 ويقوم بالreset بنفسه. نجاح CI لا يثبت تنفيذ الفائدة المقصودة. |
| [#2 — old auth recovery](https://github.com/Mina-Sayed/voya-os/pull/2) / `9978724` | CONFLICTING، verify فاشل، 77 ملفًا | لا يدمج كحزمة قديمة. استخرج فقط أي فرق ما زال لازمًا بعد مقارنة current baseline. الفشل المسجل: اختبار منع bootstrap لغير مؤكدي البريد يرى membership؛ هذا إثبات فشل الفرع/اختباره، وليس إثبات أن main الحالية تحمل نفس العيب. |

أحدث [verify على develop](https://github.com/Mina-Sayed/voya-os/actions/runs/33833359916) فاشل عند npm audit بسبب **503 من npm registry**، وليس vulnerability مثبتة في ذلك التشغيل. يحتاج إعادة تشغيل gate عند توفر المزود. نجاح PR #29 لا يستبدل تقييم إصدار يجمع الإصلاحات.

**الفلو الفعلي وجاهزية الوحدات**

| المسار | الموجود | ما يمنع اعتباره مكتملًا للإطلاق |
|---|---|---|
| التسجيل والفريق | Password/Google، onboarding مؤسسة، دعوات، عضويات، MFA، اختيار مؤسسة | MFA DB gap؛ اختبار حسابات واقعية على target الإصدار، تأكيد البريد/الدعوات/الاسترداد وأدوار الفريق. كون المستخدم suspended ولا يملك عضوية active يسمح بمسار onboarding جديد؛ قرار المنتج بشأنه ما زال مطلوبًا، وليس دليل وصول لمؤسسته الموقوفة. |
| العقارات والملاك | إنشاء/تعديل/أرشفة/استعادة، ملكية وصور خاصة وتوفر | AAL2 لكل قراءة/كتابة؛ صلاحيات target؛ البحث/التقسيم عند كثافة بيانات حقيقية. |
| CRM | leads/clients، نشاط ومتابعة وتحويل | فلو موجود واختباراته قوية؛ توحيد timezone للمتابعة إن استُخدمت نفس parser، وأحجام القوائم. لا ادعاء بوجود تسويق خارجي مكتمل. |
| الحجز | مسودة تجارية ← طلب اعتماد ← موافق مستقل ← تأكيد ← وصول/مغادرة؛ تعديل بطلب واعتماد وتنفيذ | R-02/R-04 وإكمال الإلغاء؛ historical completion وباقي استثناءات الإقامة تحتاج نطاق قبول صريح. |
| التشغيل والنقل | مهام وإسناد وإشعارات، مركبات وسائقون وإسناد رحلة وإتمامها، حماية تعارضات | timezone، نقل hardening الموجود على develop إلى مرشح الإصدار، وتجربة replay/تزامن على نفس النسخة. |
| WhatsApp | webhook HMAC، inbox، private media، human handoff، queue للرد | R-05 وعمليات العامل والمزود؛ مجرد وجود رسالة queued لا يعني delivered. |
| AI | Copilot قراءة، data-entry draft وصور خاصة وتأكيد بشري، WhatsApp agent | governance جيدة في المصدر؛ وصول AAL2 العام، flags وkill switch، واختبار النتائج والفشل والتكلفة قبل live data. |
| المالية | مبلغ تجاري للحجز؛ finance agent معطل | لا payments/expenses/commissions/settlements/general ledger. ليس نظام حسابات. لو نطاق الإطلاق يشملها فالمنتج ناقص نطاقيًا، ولا ينبغي اختراعها ضمن إصلاح الأمان. |
| التشغيل المؤسسي | audit/outbox/notifications، readiness/version/System Health في source | نسخة منشورة مطابقة، scheduler، delivery proof، monitoring/alerts وbackup restore drill. |

**ما ثبت إيجابيًا**

- اختيار modular monolith + PostgreSQL مناسب للنطاق؛ لا تظهر حاجة لإعادة كتابة أو تقسيم microservices من أدلة هذه المراجعة.
- قيود tenant-qualified FK والإشغال المتزامن وmaker-checker وidempotency/audit/outbox موجودة ولها اختبارات SQL ذات قيمة، مع الثغرات المحددة أعلاه.
- `getUser()` وtokens-only وحماية request-time/CSP موجودة؛ اختبار الإنتاج أثبت عدم shared caching للصفحات المحمية في build المحلي.
- على Staging: 41 جدول public كلها RLS-enabled. bucket الصور وbucket ai-intake خاصان، حد كل ملف 10 MiB، وأنواع JPEG/PNG/WebP فقط. لم يتم تدقيق كل storage policy/مسار الوصول الحي ضمن ذلك الاستنتاج.
- على Staging: لا SECURITY DEFINER public function قابلة للتنفيذ بواسطة anon وفق catalog الحالي. auth limiter service-role-only وسياسة ثابتة، ولا overload بأربعة arguments.
- Security advisor أعاد 35 INFO من نوع RLS بلا policies و122 WARN لدوال authenticated SECURITY DEFINER. كثير منها مقصود في تصميم RPC-only، وليست «157 ثغرة». المرجع: [RLS دون policies](https://supabase.com/docs/guides/database/database-linter?lint=0008_rls_enabled_no_policy)، [تنفيذ SECURITY DEFINER للمستخدمين](https://supabase.com/docs/guides/database/database-linter?lint=0029_authenticated_security_definer_function_executable).

**نتائج التحقق**

| التحقق | النتيجة | حدود الدليل |
|---|---|---|
| Vitest + coverage | **134 ملفًا / 609 tests نجحوا**؛ statements 82.83%، branches 72.84%، lines 88.21% | تشغيل محلي على main، وليس ضمان جميع الحالات |
| lint / typecheck | PASS | على main الحالية |
| memory validation | 11 tests + 16 required files PASS قبل التقرير | يتحقق من البنية والروابط المطلوبة، ولا يكشف كل معلومة قديمة |
| قاعدة البيانات | كامل runner للـ72 migrations PASS على `voya_cto_20260905_test` | Postgres محلي منفصل؛ لا reset لمشروع التطوير القائم |
| Regression SQL إضافية | PR10 وPR12 PASS | نفس القاعدة المحلية |
| owner concurrency | PASS | سكربت concurrency مستقل محليًا |
| Edge TypeScript | Deno check PASS | لا يثبت مزودًا حيًا أو جدولة |
| Clean production build | PASS | detached worktree بنفس SHA، npm ci، قيم build صناعية؛ cache قديمة/روابط dependencies سببت أخطاء تجهيز ثم زالت بعد التثبيت والتنظيف |
| protected production rendering | PASS، و7 unit tests للـharness PASS | لا shared-cache للصفحات المحمية في artifact المحلي |
| public browser E2E | **6/6 PASS** | isolated worktree، Chromium المحلي، يتضمن mobile/RTL/public access |
| authenticated browser E2E | **21/21 PASS في GitHub لنفس SHA** | تمت قراءة [run 33231332384](https://github.com/Mina-Sayed/voya-os/actions/runs/33231332384)، log مؤرخ 2026-09-04. لم أعد تشغيل harness محليًا لأنه يعيد ضبط stack المستخدمة من السيرفر القائم عند 3102 |
| npm audit production | **0 vulnerabilities** وقت الفحص | `--omit=dev` فقط |
| npm audit الكامل | **1 high package: browserslist** في dev dependency graph | تقرير npm يعرض advisoryين على package واحدة وfixAvailable؛ ليس ثغرة production مؤكدة. يحتاج تحديثًا وفحص سلسلة build |
| scanner self-test | PASS | اختبار guards فقط، وليس Trivy/Snyk scan. كلا scannerين نجحا في run GitHub المشار إليها؛ لم أشغلهما كفحص محلي جديد |
| اختبارات سلبية إضافية | 3 إخفاقات أمن/منطق مؤكدة: AAL1، legacy booking، PR25 cross-tenant count | تجارب صناعية transaction + rollback، تم شرح النطاق لكل واحدة |

**مطابقة النشر**

Staging تسجل 72 migration، لكن `version` أُعيد توليده بتاريخ 2026-09-04 والاسم يتضمن النسخة الأصلية من checkout. تساوي العدد/تشابه الاسم لا يثبت تساوي statements أو grants. فرق DML أعلاه مثال حي. migration الأسطول الموجودة في develop غير مسجلة هناك. يلزم mapping واضح للماضي ومنع أدوات الترقية من محاولة إعادة تطبيق التاريخ تحت IDs مختلفة.

وجود outbox-dispatch ACTIVE مع source قابل للقراءة يثبت نشر العامل فقط. غياب pg_cron لا ينفي scheduler خارجيًا. لا يوجد في هذه المراجعة إثبات لاستعادة backups أو deliverability البريد أو Meta delivery أو live Gemini؛ لم أستخدم أسرارًا لإرسال بيانات أو تشغيل عامل.

**خطة خروج من NO-GO**

1. **تثبيت مرشح واحد:** baseline نظيف على develop، فرز #2/#11/#15، عزل #25 الخطر، ودمج تغييرات CI الصغيرة حسب سياسة الريبو. حفظ SHAs ومصفوفة المigrations/grants وtarget لكل بيئة.
2. **إصلاح الأمان وصحة البيانات:** R-01، R-02، R-04، R-07، ثم #24 إذا كانت WhatsApp AI ضمن التجربة. دمج #27 بعد تعارضاته وإعادة اختبار دورة إلغاء كاملة. أولوية اختبارات الرفض/الـreplay/تعدد المستخدمين أعلى من زيادة نسبة coverage شكلية.
3. **Staging من نفس المرشح:** migrations مطابقة وصور خاصة وroles/grants مثبتة؛ فلو owner/manager/operations/sales/viewer، مؤسستان، AAL1/AAL2، رفض self-approval، منع تعارض إشغال، تعديل/إلغاء، توقيت، إعادة إرسال الأوامر، وكميات بيانات واقعية.
4. **إثبات التشغيل:** worker schedule وdead-letter/alerts ونسخ واستعادة وrollback، وثيقة مسؤول تشغيل، نشر artifact من commit نظيف مع version/readiness. تمكين المزودين يكون قرارًا صريحًا منفصلًا بعد اكتمال أدلتهم.
5. **Pilot محدود:** مؤسسة وفريق متفق عليهما بمتابعة يومية وخطة رجوع. توسيع التشغيل بعد قبول الفلو وقياسات الأخطاء والأداء. لا نسبة جاهزية مصطنعة أو موعد ثابت قبل إغلاق الموانع وإعادة الاختبار.

المنتج يمتلك أساسًا قابلًا للبناء عليه وفلو تشغيليًا واسعًا. المطلوب دورة تثبيت وأمان وإصدار موثوق، وليس إضافة مزيد من الوحدات قبل حماية القائم.
