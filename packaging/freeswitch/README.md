# Restored handset registration

`restore-registration.patch` applies to FreeSWITCH commit
`ef32e205295e29f034f1453ad245ba5efb07b94a`, in
`src/mod/endpoints/mod_sofia/sofia_reg.c`. Apply with `patch -p1` before building.
The original file SHA-256 is
`1eed13a2ae440201bcc1bf6aa1f82899140794b96202496f2e21bf2bf070c9d9`;
the patched file is
`8f1a818239d9f264e9e04a6be6e81d0e91259389be2d22f1595cda2deb3dd810`.

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

The registration quota uses the same server-owned `sip-force-user` from the
directory, with the original To user retained when no forced identity exists.
Counting the original number incorrectly rejects a different account whose
number equals an already registered authentication ID. It can also miss a
second contact for the same forced account. The quota value, domain scope and
same-Call-ID refresh exclusion remain unchanged.

Multi-registration expiry cleanup finishes synchronously before SIP 200. Its
DELETE compares the stored expiry with that registration's expiry; delaying an
older DELETE past a later same-Call-ID refresh can erase the refreshed contact.
Native tests retain both accounts through real second-boundary refreshes and
read-only SQLite/contact observations at 0, 50 and 250 milliseconds.

It preserves request From/To/Contact, normal multiple-contact responses,
authentication failures, and the existing non-REGISTER path. The global
`reg-deny-binding-fetch-and-no-lookup` workaround is not required.

Native qualification must cover original and canonical AOR pairs, numerical
identity collisions, exact response and incoming INVITE Contact URIs, refresh,
Expires:0 unregister, Contact-less binding queries, multiple contacts, ordinary
and revocable mobile accounts, and forged/disabled/revoked/suspended requests
using a previously accepted nonce, plus cross-user/tenant Call-ID replacement
and unregister isolation. Quota checks keep the limit at one: both colliding
accounts must register in either order; a second contact for one account must
be refused, while its own refresh and unregister remain valid. At least 24
actual UTC-boundary refresh cycles must also keep both contacts present after
the async SQL worker's normal batch window. Directory unit checks are in
`tests/deskphone_auth_binding.lua`; XML credential preservation checks exercise
the actual PHP writer in `tests/deskphone_directory_xml.php`. Native credentials
and SIP captures remain in private disposable-machine fixtures.
