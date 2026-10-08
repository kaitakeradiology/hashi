## Per-server configuration: size limits, TCP keepalive, the idle reaper,
## the WebSocket keepalive and the lingering close after a rejection.
##
## Set once via `serve(port, config)` (or `setServerConfig`) before the
## reactor starts; `serve` seals it, and a later `setServerConfig` aborts.
## `serve` refuses to start on a config `validateServerConfig` rejects.
##
## The definitions live in `hashi/private/cfgview`; this module re-exports all
## of them but `serverConfigView`.

import hashi/private/cfgview
export cfgview except serverConfigView
