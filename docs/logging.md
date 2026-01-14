# Logging Standard (IBM FlashSystem Plugin)

## Goals

- Make logs easy to filter and correlate.
- Keep INFO concise and consistent.
- Preserve DEBUG for step-by-step tracing.
- Avoid leaking secrets.

## Levels

- ERROR: operation failed; include cause + codes when available.
- WARN: degraded behavior, retry, timeout, or partial cleanup.
- INFO: operation start + success (business-level actions).
- DEBUG: detailed steps, API request/response timing, device discovery.

## Format

Use a single-line context prefix and a short message:

```
op=<operation> store=<storeid> vol=<volname> snap=<snap> vmid=<vmid> msg=<message>
```

Context keys are optional; include only what is relevant. Preferred key order:

```
op store vol snap vmid host pool endpoint method fcmap uid device size delta elapsed_ms
```

Notes:
- `size` and `delta` are bytes.
- `elapsed_ms` is added on success logs.

## Start/End Pattern

- INFO at start: `msg=start`
- INFO at end: `msg=ok` (with `elapsed_ms`)

## Errors

- ERROR should include the reason and, if available, `code` (CMMVC/HTTP).
- Do not log full stack traces.
- Ensure sensitive data is sanitized.

## Debug

- Use DEBUG for loops, polling, or internal steps.
- Log only the minimum required for tracing.

## Examples

```
op=alloc_image store=ibm1 vol=vm-100-disk-0 vmid=100 pool=pool0 size=10737418240 msg=start
op=alloc_image store=ibm1 vol=vm-100-disk-0 vmid=100 pool=pool0 size=10737418240 elapsed_ms=512 msg=ok

op=volume_snapshot store=ibm1 vol=vm-100-disk-0 snap=backup-1 msg=start
op=volume_snapshot store=ibm1 vol=vm-100-disk-0 snap=backup-1 elapsed_ms=742 msg=ok
```
