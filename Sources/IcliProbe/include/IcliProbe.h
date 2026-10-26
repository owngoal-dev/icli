#pragma once

#include <stdbool.h>

// The probe is a JavaScriptCore scripting shell: a script reaches the device
// frameworks through an ObjC reflection bridge, reads and writes files, prints,
// and calls back into its host through api(). It is the port of vphoned's
// script session into icli, and everything here runs INLINE, in the calling
// process. There is no detach: a script that crashes or never returns takes
// the caller down with it. A host that needs isolation spawns `icli probe` as
// its own process, which is what vphoned does.
//
// JavaScriptCore is loaded with dlopen rather than linked, so the binary still
// builds and loads on a platform that does not ship it (icli targets iOS and
// tvOS, which both do); icli_probe_available() is false there and evaluation
// fails with "This platform has no JavaScriptCore". Nothing here is a
// process-launch import: `scripts/verify-binary.py` keeps passing and
// `env info` stays `spawns_processes: false`.
//
// Every symbol is prefixed icli_probe_ / IcliProbe so a host that links this
// next to vphoned's own VPObjCHandle / vp_js_* has no collision.

#ifdef __cplusplus
extern "C" {
#endif

/// Whether JavaScriptCore can be loaded in this process. False only on a
/// platform that does not ship it, where the probe is unavailable.
bool icli_probe_available(void);

/// Evaluate `source` in the process's shared context, built on first use.
/// Returns the described result (malloc-owned), or NULL with `*error` set to a
/// malloc-owned message; a context that cannot start, JavaScriptCore missing
/// included, is such an error. With `output`, what the script prints is
/// collected instead of reaching the terminal and handed back as a
/// malloc-owned `*output`, NULL only when no context started, so one-shot
/// evaluation keeps stdout for its JSON line; the REPL passes NULL and its
/// output appears as it happens. The caller frees whatever it gets.
char *icli_probe_evaluate(const char *source, char **error, char **output);

/// The handler api(method, params) calls. `request` is a NUL-terminated JSON
/// object {"method":"..","params":{..}}, params as JSON.stringify encoded them; the reply must be a malloc-owned,
/// NUL-terminated JSON object {"result":..} or {"error":{"code":..,"message":..}},
/// or NULL. The handler stays until replaced; NULL makes api() throw.
void icli_probe_set_api_handler(char *(*handler)(const char *request));

/// Run the interactive REPL on this process's own stdin and stdout until end
/// of input or `.exit`, and return its exit status. Output is live, not
/// captured. This drives `icli probe repl`; it runs inline, so it never
/// detaches the process group the way a separate session process would.
/// SIGINT is caught only while a line is read, where ^C abandons a
/// half-finished statement; while a statement runs, SIGINT keeps the
/// caller's own disposition, which by default ends the process.
int icli_probe_repl(void);

#ifdef __cplusplus
}
#endif
