# Users, departments and call routing

These controls are included in **1.0.14**. See the [release status](feature-coverage.md#users-and-departments--1014) for installation, publication and deployment results.

## Phone status and internal calls after hours

The hosted instance received these additions on **19 October 2026**, as a narrow patch on core **1.0.16**. They are also in current source; the complete 1.0.17 package is still under qualification.

**Admin → Users** and the staff **People** page show **Online** when an enabled user has a current registered desk phone or app connection, and **Offline** otherwise. The table refreshes every five seconds while visible. **Status unavailable** means the check failed; it does not mean the phone is offline. The desktop's Connected Phones total counts users with at least one connected phone. Multiple devices belonging to one user count once.

**Call Status** remains separate: a phone can be Online while its user's calls follow Out of office rules. Registration alone does not prove that someone can answer or hear a call.

To let colleagues call a user after closing time, open **Users → user → Call Forwarding → Allow internal calls outside office hours**, then save. The option starts off for other users. It allows direct calls from authenticated extensions to registered desk phones and app connections without the automatic office-hours status switch. Outside calls, queues, ring groups, custom closed-hours destinations and manually selected Away, Out of office or Do Not Disturb keep their existing rules. External Ring My Mobile forwarding also retains its ordinary office-hours checks. Ring time and no-answer destinations remain as configured.

For the hosted OpenWeb PBX, this option is enabled for **1000, 1049, 1050 and 1051**. Extension **1000** now has **OpenWeb** as its primary department, preserving its other memberships. The three International Lighting phones remain on `openweb.sip.openwebpbx.com` with their original restored credentials. See [the verification record](feature-coverage.md#hosted-phone-status-and-after-hours-internal-calls--2026-10-19).

## Add a user

Open **Admin → Users → Add User**. An available extension is already filled in. Enter the person's name and save.

The suggestion follows the extension length already used by the PBX; an empty PBX starts at 1000. It avoids existing users, authentication IDs, phone aliases, voicemail boxes, queues, ring groups, receptionists and numbered dialplans in this PBX. Other tenants may use the same extension numbers independently.

Leave **Assign an available extension automatically** selected to check again when saving. Two administrators can submit the same suggestion and receive different free extensions. Enter another number to choose it yourself; a conflicting manual choice is rejected. This changes the proposed number before creation. Renumbering an existing user remains a separate migration operation.

## Departments and ring groups

Departments organize users and call-handling objects and supply shared office hours. Ring Groups define which phones ring when a call arrives. They have separate member lists.

Open **Admin → Departments** to select users, queues, ring groups, digital receptionists, call scripts and SIP trunks. Adding a member preserves their existing primary department. A user can belong to more than one department; choose the primary department on the user's **General** tab and additional memberships under **Additional Departments**.

Open **Admin → Office Hours** to set a department's timezone, opening periods, breaks, holidays or temporary Open/Closed override. Under **Call Handling**, choose the item's department and whether it follows department hours, stays open, or keeps its existing custom hours. Select destinations for closed hours, breaks and holidays. **Continue Normal Ringing** retains the item's normal behavior for that period.

Under **DID Numbers**, the **Office Hours Department** can override the destination's department. **Use Office Hours** and **Use Holiday Destination** enable the corresponding destinations. Use **Call Routing → Where Will This Call Go?** to preview users, incoming numbers, queues, ring groups and receptionists at a selected time.

## Outbound rules

Under **Admin → Outbound Rules → Who Can Use This Rule?**, select departments and/or enter extensions such as `1000, 1010-1020`. A caller matching either selection can use that rule. Leave both empty to allow everyone in the PBX. Trunk selection, prefix and number-length conditions still apply.

New selections store department identifiers, so renaming a department retains the restriction. Restored rules that refer to department names are updated when that department is renamed. A rule containing an unavailable restored department requires explicit confirmation before removing that restriction. An unavailable identifier never turns a restricted rule into an unrestricted rule.

## Directory visibility and permissions

**Show members to everyone in this PBX** controls the Android directory. When disabled, a member is visible to people who share a department, and to themselves. Membership in another published department can also make that person visible. Existing departments keep their previous visibility until explicitly changed. This setting does not grant administration or call-control permissions.

Tenant and instance permissions continue to protect PBX administration. Full department-scoped staff roles, cross-department call-view permissions, Barge-In/Listen/Whisper, language/prompt inheritance and department-specific hold music remain separate roadmap work; this release does not claim complete 3CX department parity.

The workflow follows the distinctions described in the official [3CX Departments guide](https://www.3cx.com/docs/manual/departments/), [Office Hours guide](https://www.3cx.com/docs/manual/office-hours/) and [Access Roles guide](https://www.3cx.com/docs/manual/access-roles/). See [3CX.md](../3CX.md) for the wider acceptance plan.
