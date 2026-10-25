# Windows Server 1.0.21 qualification

This candidate adds five-minute Windows update checks, native and web required-update notices, Keoma Greetings, group-managed company hours and opt-in extension office routing. Publication and deployment were explicitly requested on 25 October 2026. The public Windows installer remains 1.0.20 until the new package's required checks pass.

Source starts at `4f755359d` with matching 1.0.21 native/version metadata. Native build `40204829730` passes before the subsequent maintenance-lease correction; its result cannot qualify changed worker bytes. A matching new native build and fresh complete installer run are required.

Release preparation identified that the new Greetings worker must observe Windows maintenance before writing its heartbeat or starting work. The original all-public welcome fingerprint and every customer/greeting configuration row must remain protected. Replacement restore and upgrade checks need explicit treatment of only a generated heartbeat timestamp, with other fields and full table inventories preserved.

The earlier component checks remain scoped: 82 updater, 85 update-policy/notice, 49 Greetings PostgreSQL, 39 Greetings worker, 52 recorder, 53 group-hours, 142 staff-role, 218 schedule-policy and 209 synthetic routing controls. A real Debian recorder-helper loopback proves Keoma instructions, #, replay and saved audio; it does not establish complete routed customer-phone or Windows recording acceptance.

New full installation, native calls/media, backups, signed upgrades and replacement restore are recorded here as each completes. Published 1.0.20 results remain historical and do not qualify 1.0.21 bytes. Existing Android and Debian update envelopes must be preserved exactly; the Windows ordinary update feed retains minimum version 1.0.20. Legacy owner migration, real reboot and external physical-phone/provider/camera checks remain separate.
