// The CEF engine's side of Iris's page for a failing certificate
// (interstitial.odin): "Show anyway" makes the tab again in the sandbox and
// loads the page there, where on_certificate_error (cef_view.odin) lets
// this tab's chosen host through.
package iris

import "core:strings"

// (not indented: the whole file is this engine's)

tab_cert_proceed :: proc(t: ^Tab, url, host: string, engine: rawptr) {
	// the host is in the sandbox this run (cert_host_sandboxed): tab_load
	// makes the tab again there if it is not, and forgets its certificates
	tab_load(t, url)
	if len(host) > 0 && host not_in t.allowed_certs do t.allowed_certs[strings.clone(host)] = true
}

/// CEF keeps no hold on the certificate for Iris (it asks again)
tab_cert_release :: proc(engine: rawptr) {}

