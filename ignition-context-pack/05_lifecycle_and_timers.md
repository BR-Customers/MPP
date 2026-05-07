# Lifecycle scripts + timer scripts

Project-level scripts that don't belong to a specific view: startup / shutdown / update hooks, and gateway-scheduled timers.

## Lifecycle scripts

`ignition/{startup,shutdown,update}/` each hold one resource folder containing a single `.py` file plus its `resource.json`.

### Startup — `ignition/startup/onStartup.py`

```python
def onStartup():
    """Called when the project loads on the gateway."""
    pass
```

Use for one-time setup the project needs at load time: priming caches, warming up tag subscriptions, registering message handlers via `system.util.invokeAsynchronous`. Keep it light — a slow startup blocks the project from going live.

`scope: "G"` — gateway only.

### Shutdown — `ignition/shutdown/onShutdown.py`

```python
def onShutdown():
    """Called when the project unloads (gateway shutting down or project disabled)."""
    pass
```

Use for releasing resources: closing file handles, flushing buffered logs, cleanly disconnecting from external services. Don't rely on it for critical persistence — if the gateway crashes, this won't run.

### Update — `ignition/update/onUpdate.py`

```python
def onUpdate(actor, resources):
    """Called when project resources change at runtime."""
    pass
```

Fires when project resources are modified, added, or removed (e.g., a developer saves a view in the Designer, or a `git pull` plus gateway-scan delivers new files).

- `actor` — username of whoever made the change
- `resources` — collection describing what changed

Use for: invalidating in-memory caches that depend on view / proc / config content; logging deployment events; triggering downstream notifications when a new version of a critical resource ships.

## Timer scripts

`ignition/timer/<TimerName>/handleTimerEvent.py` plus `resource.json`:

```python
def handleTimerEvent():
    """Called every <delay> ms (per the resource.json config)."""
    # ...
```

`resource.json`:

```json
{
  "scope": "G",
  "version": 1,
  "files": ["handleTimerEvent.py"],
  "attributes": {
    "delay": 60000,
    "fixedDelay": true,
    "sharedThread": true,
    "enabled": true,
    "lastModification": { "actor": "...", "timestamp": "..." }
  }
}
```

| Attribute | Meaning |
|---|---|
| `delay` | Tick interval in ms. `60000` = 1 minute. |
| `fixedDelay` | `true` = wait `delay` ms after the previous run completes. `false` = fire every `delay` ms regardless of whether the previous run is still running (rate-locked, can drift if execution is slow). |
| `sharedThread` | `true` = use Ignition's shared timer-thread pool. `false` = dedicated thread (use only for high-frequency or long-running timers; consumes a thread continuously). |
| `enabled` | `false` to disable the timer without removing the resource. |

### Example — periodic OPC sync

```python
def handleTimerEvent():
    tags = system.opc.browse('SomeOpcServer', folderPath='*FileSystem/Settings.h')
    try:
        path = str(tags[0].getOpcItemPath())
    except:
        path = 'NotFound'
    system.tag.writeBlocking(['[default]ConfigFilePath'], [path])
```

This pattern — read from OPC, write to tag — is a common timer-script use. The `try/except` around `tags[0]` guards the case where the OPC path isn't there; without it, the timer throws and the gateway log accumulates noise.

### Choosing `delay`

| Use case | Suggested `delay` |
|---|---|
| Heartbeat / keep-alive | 5000 – 30000 ms |
| External state polling (config files, EDI inboxes) | 60000 – 600000 ms |
| Periodic reconciliation (DB ↔ external) | 300000 – 3600000 ms |
| Daily / hourly summaries | Use Gateway Event Scripts → Scheduled instead of timers |

For sub-second timers, prefer Tag Change Scripts (event-driven) over polling — much lighter on the gateway.

## Anti-patterns

### Don't use per-tag Tag Change Scripts for application logic

Older Ignition projects sometimes attach Python scripts directly to individual tags via "Tag Change Scripts." This pattern has real problems:

- **Thread pool exhaustion** — every tag with a script consumes from the same pool; a slow script blocks others
- **Scripts scattered across the tag tree** — hard to discover, hard to test, hard to refactor
- **Memory leaks** — observed in production with long-running gateways

**Use Project Tag Change Scripts (gateway-level) instead.** These run on a separate execution model and are much better-behaved. Inside the gateway-event script, call into a project script as a one-liner:

```python
# Gateway tag change event:
project.<integrator>.<Domain>.<Entity>.handleTagChange(tagPath, currentValue.value)
```

The actual logic lives in the project script and stays version-controlled, testable, and discoverable.

### Don't put long logic inline in lifecycle / timer scripts

Same rule as inline view-event scripts: anything past 1–3 lines factors into a project script and is called as a one-liner. Lifecycle + timer scripts should be dispatch surfaces, not logic surfaces:

```python
def handleTimerEvent():
    project.<integrator>.<Domain>.HourlyReconcile.run()
```

That way the actual logic in `<integrator>.<Domain>.HourlyReconcile.run()` is testable from the Designer's Script Console, callable from other places, and visible in any IDE search.
