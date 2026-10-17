# SIP.js

`sip.js` is a local ES module bundle of the official `sip.js@0.21.2` npm
package. No CDN request, tracking resource or external JavaScript is used.
The package tarball's published SHA-512 integrity is
`tSqTcIgrOd2IhP/rd70JablvAp+fSfLSxO4hGNY6LkWRY1SKygTO7OtJEV/BQb8oIxtMRx0LE7nUF2MaqGbFzA==`.
Its MIT license is retained in `LICENSE-SIP.js.md`.

Rebuild from the verified npm package with esbuild 0.25.0:

```
npm pack sip.js@0.21.2
tar -xzf sip.js-0.21.2.tgz
npx esbuild@0.25.0 package/lib/api/index.js --bundle --format=esm --minify --legal-comments=eof --outfile=sip.js
```

Upstream: <https://github.com/onsip/SIP.js/tree/0.21.2>
