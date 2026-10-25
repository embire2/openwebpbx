# Company office hours and extension routing

Open **Admin → Departments**, choose the company group, for example **Global Lighting**, and find **Office Hours for This Company Group**.

- **Keep Current Office Hours** saves membership and name changes without changing the schedule.
- **Set or Edit Office Hours** lets you set the time zone, opening periods, breaks, holiday dates and a temporary Open/Closed override. An overnight period such as Monday 22:00–02:00 continues into Tuesday.
- **Delete Office Hours** removes that group's opening periods, breaks, holidays and temporary override. The group becomes **Always Open**. Its members, incoming/outgoing call rules and other companies' schedules remain unchanged.

Choose **Save** to apply the selected action. The separate **Office Hours** page uses the same editor and also allows schedule deletion. A department administrator can manage only the schedules delegated to that administrator.

To choose different destinations for an extension, open **Admin → Users → extension → Office Hours Routing**. Assign its primary company group on **General**, then enable **Use Different In-Office and Out-of-Office Destinations**. Select the destination for **In Office** and **Out of Office**, then save. Breaks and holidays use the Out of Office destination. Targets can include another extension, voicemail, a ring group, queue, digital receptionist, outside number or ending the call.

**Keep Existing Call Rules** keeps normal status, ringing and unanswered-call rules for that period. The new routing is off until explicitly enabled; existing restored settings are preserved. Disabling it returns the extension to its previous routing rules while retaining its saved open/closed choices.

The existing **Call Forwarding → Allow internal calls outside office hours** setting still allows authenticated calls between extensions after hours. Provider calls and caller-ID hints cannot use this exception. Manually selected Away and Do Not Disturb states retain their existing behavior when normal ringing rules apply.

**Call Routing** previews now show the selected in-office or out-of-office destination at the date and time you choose. Routing and previews use the same company time zone, breaks, holidays and overrides.

Validation covers actual isolated PostgreSQL saves and permission refusals, schedule decisions and the complete Lua user-routing entry. It preserves native SIP authentication identities/passwords and other tenants' configuration. No customer phones or outside numbers are called by these tests. Windows package and physical-phone acceptance remain separate from these portable PHP/Lua checks.
