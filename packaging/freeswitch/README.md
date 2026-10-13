# Restored handset registration

`restore-registration.patch` applies to FreeSWITCH commit
`ef32e205295e29f034f1453ad245ba5efb07b94a`, in
`src/mod/endpoints/mod_sofia/sofia_reg.c`. Apply with `patch -p1` before building.
The original file SHA-256 is
`1eed13a2ae440201bcc1bf6aa1f82899140794b96202496f2e21bf2bf070c9d9`;
the patched file is
`4dafe992533cbff6e57a5bb6870cb2b410fb552d781e657a55fefd9ad73f241d`.

Restored phones retain their original SIP extension and separate digest
username. The directory binds that pair to one enabled user in the requested
tenant before authentication caching and returns a server-owned canonical
`sip-force-user`. This gives each native contact an unambiguous authentication
identity, including when one person's authentication ID equals another person's
original extension number.

The upstream registration path applies that identity only when expiry is
nonzero, and looks up response bindings with the original From user. Therefore
an otherwise successful registration can omit its Contact response, an
Expires:0 unregister can leave its canonical binding, and a Contact-less binding
query can miss the registered phone. The patch applies the trusted identity
only after successful REGISTER authentication, regardless of Contact or expiry,
and queries response bindings with the same canonical key used for storage.
The two Call-ID-based replacement/removal queries also constrain the
authenticated canonical SIP user and domain. Otherwise another authenticated
account can remove a foreign binding by supplying its Call-ID.

It preserves request From/To/Contact, normal multiple-contact responses,
authentication failures, and the existing non-REGISTER path. The global
`reg-deny-binding-fetch-and-no-lookup` workaround is not required.

Native qualification must cover original and canonical AOR pairs, numerical
identity collisions, exact response and incoming INVITE Contact URIs, refresh,
Expires:0 unregister, Contact-less binding queries, multiple contacts, ordinary
and revocable mobile accounts, and forged/disabled/revoked/suspended requests
using a previously accepted nonce, plus cross-user/tenant Call-ID replacement
and unregister isolation. Directory unit checks are in
`tests/deskphone_auth_binding.lua`; XML credential preservation checks exercise
the actual PHP writer in `tests/deskphone_directory_xml.php`. Native credentials
and SIP captures remain in private disposable-machine fixtures.
