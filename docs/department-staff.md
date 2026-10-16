# Department staff access

Instance and tenant owners keep their existing administration access. **Admin → Staff Access** opens the department workspace, where an owner can invite staff and assign a role for each department. Staff sign in with their own email address and open **My PBX**.

| Role | Available actions in its departments |
|---|---|
| User | Published People directory, own status, phone setup, voicemail, recordings and call history |
| Receptionist | User actions, live calls, hold/resume, transfer/pickup, parking, ending calls and temporary Open/Closed overrides |
| Supervisor | User actions, live queues, agent Ready/Break/Sign Out and queue/call reports |
| Department Administrator | User actions, users, phone setup, SIP trunks, ring groups, queues, digital receptionists and office hours |
| Manager | User actions, receptionist and supervisor actions, users and department recordings |
| Owner | All department actions and delegation of lower staff roles |

A department Owner cannot create another Owner or change an Owner account; the existing PBX owner handles that. Managers and department administrators cannot edit peer or higher staff accounts. Shared objects can be changed only when the staff member manages all their departments. Instance settings, tenant creation, backups, global dialing rules and provider handover remain with the PBX owner.

Choose the extension, department, role and web-login email. A new account starts disabled and receives a private, single-use invitation valid for 48 hours. Choose **Email the invitation** to queue it through the instance's global mail server, or share the displayed link privately. The recipient creates a separate web password; SIP passwords remain unchanged. **Renew Invitation** invalidates the earlier link. **Revoke** removes the role immediately on subsequent requests, including existing sessions. Disabling the account or extension, moving it out of the assigned department, or suspending its tenant also removes access.

People visibility follows the department's published/shared directory settings. Call controls use server-assigned call ownership. Reports, audio downloads and QR-code actions repeat their permission checks on the server. A hidden button is not the access control. Staff cannot obtain another department's phone setup by changing a URL.

This implements the roles above for the existing OpenWeb workflows. It does not add call monitoring/barge-in, new second-factor methods, or every role-dependent 3CX feature. Those remain tracked in [3CX.md](../3CX.md).
