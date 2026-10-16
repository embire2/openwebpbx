# Users, departments and call routing

These controls are included in the **1.0.14 candidate**. The published baseline remains 1.0.12 until release qualification and publication finish.

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
