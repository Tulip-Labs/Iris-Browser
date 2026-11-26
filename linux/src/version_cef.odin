// The Chromium (CEF) build's own version. It ships on releases of its own
// (tags cef-vX.Y.Z, .github/workflows/release-cef.yml), apart from the WPE
// build and Android (VERSION in shields.odin, tags vX.Y.Z), so the two
// numbers move independently. packaging/check/versions-cef.sh checks this
// against packaging/release-notes-cef.md and the cef-v tag.
package iris

CEF_VERSION :: "2.4.2"

/// the version of this build: CEF_VERSION in the CEF build, VERSION in the WPE one
when ENGINE_CEF { BUILD_VERSION :: CEF_VERSION } else { BUILD_VERSION :: VERSION }
