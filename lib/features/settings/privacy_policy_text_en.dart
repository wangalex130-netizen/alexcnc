/// 隐私政策**英文正文**（2026-10-05 机翻）。
///
/// ⚠️⚠️⚠️ 法律风险告知（务必阅读，勿直接发布）
/// 本文件是**机器翻译**结果，未经法务审校。隐私政策是具法律效力的文本，
/// 机翻常导致：
///   ·术语不对等（如「个人信息」vs "personal information" 在不同法域定义不同）
///   · 义务表述失准（"应当/可以/不得" 三种强度会被混译）
///   · GDPR / CCPA / 中国个保法 的条款义务表述差异被抹平
///   · 引用的法规名称不准确
/// **发布前必须经法务审校。** 审校重点见文末「需人工确认清单」。
///
/// 与中文版的对应关系：`privacy_policy_text.dart`（同一版本号 V1.0）。
/// 结构、章节号、表格行、分段位置**逐段对齐**，便于法务逐条比对。
///
/// ★ 2026-10-05 修正：权限表按 APK 实际打包结果补充了 4 条 ——
///   CAMERA（来自 mobile_scanner 插件）与 3 条定位 + QUERY_ALL_PACKAGES
///   （来自推送 SDK com.getui:gtsdk，构建时自动合并，无法单独移除）。
library;

/// 英文版版本号，与中文版一致。
const String kPrivacyPolicyVersionEn = 'V1.0';

/// 隐私政策英文正文（纯文本，用 \n 分段）。
const String kPrivacyPolicyTextEn = '''
Smart CNC Pro Privacy Policy
$kPrivacyPolicyVersionEn

Effective date: September 1, 2026
Last updated: October 1, 2026

Alex Wang (hereinafter referred to as "we," "us," or "our") understands the importance of your personal information and will do everything possible to protect its security and reliability. We are committed to maintaining your trust and strictly follow the principles below when protecting your personal information: accountability, purpose limitation, informed consent, data minimization, security safeguards, participation, and transparency.

Please read and understand this Privacy Policy carefully before using Smart CNC Pro (hereinafter referred to as "this App"). By tapping "Agree" or by starting to use this App, you confirm that you have fully understood and agreed to all the contents of this policy.

This App is the companion control and monitoring software for a desktop CNC engraving machine. It helps you view machine status remotely, submit carving jobs, and track carving progress.


I. How we collect and use your information

We collect and use your information only for the purposes described in this policy:

1. Account and sign-in
   Collected: your account identifier (such as phone number or username), your encrypted sign-in credentials, and your session token.
   Purpose: to create and sign in to your account, verify your identity, and link machines to your account.
   Note: your password is encrypted before transmission. We never store your plaintext password.

2. Machine linking and device information
   Collected: machine unique ID (device serial number), machine model, linkage relationship, carving jobs, and history records.
   Purpose: to link your engraving machine to your account so that you can only see and operate machines registered under your account, and to save and display your carving history.

3. Network and connection information
   Collected: the name and connection state of the current Wi-Fi network, the phone's IP address on the local network, the engraving machine's local network address and port, and network reachability probe results (used to determine whether the phone and the machine are on the same network).
   Purpose: to automatically discover and connect to your engraving machine over the same Wi-Fi network, and to determine whether functions requiring close-range operation are currently available.
   Note: the App itself does not collect your location information and does not request location permission.
   ★ Disclosure: the bundled push service (GeTui) declares location-related permissions in its SDK
   (ACCESS_FINE_LOCATION / ACCESS_COARSE_LOCATION / ACCESS_BACKGROUND_LOCATION) and app-list read permission
   (QUERY_ALL_PACKAGES). These are merged automatically at build time by the push SDK and cannot be
   removed without breaking push delivery. The location permissions are used by the push service for
   regional scheduling and statistics only. We do not read, store, or display your location.
   Denying them does not affect any other feature, but may reduce push delivery rate.

4. Device control and operating status
   Collected: the engraving machine's operating status (idle, carving, alarm, etc.), tool coordinates, spindle speed, carving progress, alarms, and error codes.
   Purpose: to show you machine status in real time and let you issue control commands such as start, pause, stop, and jog.

5. Live video feed
   Collected: the live feed from the camera installed on your engraving machine.
   Purpose: to let you remotely view the machining process inside the machine.
   Note: the feed comes from the machine-side camera. This App does not access your phone's camera, and it does not collect or upload anything from your photo gallery.

6. Notifications and push messages
   Collected: the push service client ID (CID), notification preference settings, device model, and OS version, plus other basic information required for push delivery.
   Purpose: to notify you when a carving job finishes, fails, or when a safety alarm occurs.
   Note: push delivery relies on a third-party push service (see Section III). That service collects the necessary device information under its own rules. You can turn off notifications in your system settings.

7. Diagnostics and logs
   Collected: App runtime logs, crash information, and API logs for cloud communication.
   Purpose: to troubleshoot faults and locate problems.
   Note: these are generated and uploaded only when you actively tap buttons such as "Smart diagnostics and log export". They are never uploaded automatically in the background.

8. Local storage
   Collected: carving history, your preference settings, and cached machine connection addresses.
   Purpose: to let you quickly restore your working state the next time you open the App.
   Note: this data is stored primarily on your phone.


II. System permissions we request and their purposes

To provide the features above, this App requests the following system permissions. You may revoke any authorization in your phone's system settings at any time. Revoking a permission disables the corresponding feature but does not affect other features.

| Permission | Purpose |
|---|---|
| Internet access (INTERNET) | Communicate with the cloud server and the engraving machine |
| Network state / Wi-Fi state (ACCESS_NETWORK_STATE, ACCESS_WIFI_STATE, CHANGE_WIFI_STATE) | Determine the network type and discover the engraving machine on the same Wi-Fi network |
| Multicast network (CHANGE_WIFI_MULTICAST_STATE) | Discover the engraving machine via local network broadcast |
| Notifications (POST_NOTIFICATIONS) | Push notifications when carving finishes, fails, or a safety alarm occurs |
| Storage / Gallery (READ_EXTERNAL_STORAGE, WRITE_EXTERNAL_STORAGE, READ_MEDIA_IMAGES) | Write images to your gallery only when you actively save a snapshot. We never read anything else in your gallery |
| Vibration (VIBRATE) | Operation feedback and alarm reminders |
| Boot start / Background wake-up (RECEIVE_BOOT_COMPLETED, WAKE_LOCK, SCHEDULE_EXACT_ALARM) | Ensure push messages are delivered promptly |
| Device information (READ_PHONE_STATE) | Used by the third-party push service to identify the device and deliver vendor-channel messages |
| Camera (CAMERA) | Scan the QR code on the machine only when you use "Scan to link a machine" (never invoked otherwise) |
| Location (FINE / COARSE / BACKGROUND_LOCATION) | **Introduced by the bundled push service (GeTui).** Used only for regional scheduling and statistics. We do not read, store, or display your location. Denying it does not affect other features; push delivery rate may drop |
| App list read (QUERY_ALL_PACKAGES) | **Introduced by the bundled push service (GeTui).** Used to determine which vendor channels are available. We do not read information about your other installed apps |


III. How we entrust, share, transfer, and publicly disclose your information

1. We do not sell your personal information to any third party.
2. To provide the basic functions of this App, we rely on the following third-party services, each of which processes the necessary information under its own privacy policy:

   GeTui (Beijing Diandatong Technology Co., Ltd.): provides the message push service and collects the push client identifier and necessary device information.
   Alibaba Cloud: provides account, machine linkage, job, and model library services.
   Tencent Cloud EMQX: provides the messaging service between the device and the App.
   Video relay service: when you view the machine feed, the video data is forwarded through this service.

3. Except for the following circumstances, we do not share your information externally: with your explicit consent; or as required by law or by the mandatory demands of competent authorities.


IV. How we store and protect your information

1. Storage location: your information is stored on servers we use or lease within the People's Republic of China.
2. Retention period: we keep your information only for as long as necessary to provide the service to you. After that period, we delete or anonymize it.
3. Safeguards: we protect your information through encrypted transmission (HTTPS / TLS), access control, and other measures. Communication between the device and the server uses encrypted connections.
4. Security notice: please safeguard your account and password. No internet environment is absolutely secure. We will do our best to keep your information safe, but we cannot guarantee absolute security at all times.


V. Your rights

1. Access and correction: you can view your account information and machine information on the "Profile" page, and modify some of it.
2. Deletion: you can delete your carving history. To delete your account information, contact us using the method at the bottom of this policy.
3. Withdrawing consent: you can revoke authorizations such as notifications and storage in your system settings. You can also view this policy under "Profile - Privacy Policy".
4. Account closure: to close your account, contact us using the method at the bottom of this policy. After closure, we will delete or anonymize your personal information.
5. Turning off personalized push: you can turn off specific notification types in the notification settings on the "Profile" page.


VI. Protection of minors

This App is a desktop CNC device management tool intended for adult users. We do not proactively collect the personal information of minors. If you are a minor, please read this policy with a guardian present and use this App only after obtaining the guardian's consent.


VII. Updates to this policy

We may update this policy from time to time. After an update, we will notify you prominently within this App. If you continue using this App after the policy is updated, you are deemed to have accepted the updated policy.


VIII. How to contact us

If you have any questions, comments, or suggestions about this Privacy Policy, or wish to exercise any of the rights described above, please contact us:

Developer: Alex Wang
Contact email: repipop@163.com

We will respond within 15 business days after receiving your feedback.
''';
