# Import and generated-code status

Updated: 2026-08-22

This file records facts from generated artifacts and runtime evidence. An
import is not classified as fully implemented merely because its declaration
was generated or the runtime found a symbol; an exercised export may still be
a partial implementation.

## Target and generated code

- Target: `game/Default.xex`, SHA-256
  `0bb765d0c89de2674efea76056a9c1b6236173587398ddc248b08cc1a6092883`.
- Image range: `0x82000000-0x83220000`; code range:
  `0x82240000-0x82EB6720`; guest entry (`xstart`): `0x82BA5C78`.
- Generator/runtime baseline: ReXGlue `0.10.0-dev.g398e2ba`.
- The complete native build reached `[222/222]`. The latest runtime-backed
  generated set registered 47,091 functions (zero duplicates, zero rejected).

The manifest contains five title-specific hints, all bounded from this exact
XEX rather than copied from another title:

| Guest address | Size | Boundary evidence | Runtime status |
|---|---:|---|---|
| `0x82A6D088` | `0x14` | Five-instruction copy helper; `blr` at `0x82A6D098`, padding at `0x82A6D09C`, next function at `0x82A6D0A0` | Included in tested build |
| `0x823F87E8` | `0x20` | Null-safe initializer; `blr` at `0x823F8804`, next function at `0x823F8808` | Included in tested build; cleared prior fatal |
| `0x828C8398` | `0x18` | Vtable initializer; `blr` at `0x828C83AC`, next PDATA at `0x828C83B0` | Included in tested build; cleared prior fatal |
| `0x8231ED50` | `0x8` | Constant-return stub; `blr` at `0x8231ED54`, preceded by `bctr` at `0x8231ED4C`, next PDATA at `0x8231ED58` | Included in tested build; cleared prior fatal |
| `0x82275238` | `0x18` | Table dispatcher; `bctr` at `0x8227524C`, preceded by a dispatch ending at `0x82275238`, next PDATA function at `0x82275250` | Present in manifest; post-change build/runtime proof pending |

For the current target, core evidence gives LR `0x8228346C`, CTR
`0x82275238`, and the indirect `bctrl` at `0x82283468`. The tested registration
count remains 47,091; 47,092 cannot be claimed until a new runtime log records
it.

## Import accounting

| Library | Function thunks | Variables | Total records |
|---|---:|---:|---:|
| `xboxkrnl` | 157 | 12 | 169 |
| `xam` | 113 | 0 | 113 |
| **Total** | **270** | **12** | **282** |

The bounded boot log shows symbol creation for both libraries and patches all
12 variable imports. It does not report an unresolved-import, missing-export,
or explicit stub diagnostic on the exercised path. It also dynamically looks
up several party/community `xam` ordinals. None of those facts proves that all
282 exports have complete behavior.

The 12 observed variable patches are `ExThreadObjectType`,
`KeDebugMonitorData`, `XboxKrnlVersion`, `XexExecutableModuleHandle`,
`ExLoadedCommandLine`, `XboxHardwareInfo`, `VdGlobalDevice`,
`VdGlobalXamDevice`, `KeCertMonitorData`, `VdGpuClockInMHz`,
`VdHSIOCalibrationLock`, and `KeTimeStampBundle`.

## Exercised import domains

| Domain | Status | Current evidence |
|---|---|---|
| XEX/module loading | IMPLEMENTED | The exact main XEX is mapped, its imports are bound and `xstart` executes. This does not claim support for arbitrary modules. |
| Memory, threads and synchronization | PARTIAL | Guest threads, waits, TLS and GPU/audio workers run through the captured boot; edge cases are not audited. |
| Filesystem/VFS | PARTIAL | The legal game root and packaged data are read. Missing locale/movie probes return errors without stopping this boot path. |
| Video/Xenos | PARTIAL | Render targets, shader pipelines, guest draws, 1280x720 presents and a visible guest frame are proven. |
| Audio/XMA | PARTIAL | The XMA worker and six-channel 48 kHz SDL endpoint initialize and receive submitted frames; audible correctness is unverified. |
| Notifications/content (`XamNotify*`, `XamContent*`) | PARTIAL | `XamNotifyCreateListener` returns handles and `XamContentCreateEnumerator` returns an empty enumerator on the exercised path. |
| `XLiveBaseUnk58046` | STUBBED | The runtime explicitly reports this exercised call as `unimplemented`; execution continues past it before the unrelated PPC trap. |
| Input (`XamInput*`) | NOT HIT | No Saw II guest input query is present before the current trap; SDL host enumeration alone is not guest-input proof. |
| Other generated XAM/kernel exports | NOT HIT | Registration alone is not treated as behavioral evidence. |
| Current unregistered PPC target | BLOCKING | This is a missing title-specific LTCG function boundary, not an unresolved Xbox import. |

## Runtime interpretation

The latest tested binary loads the intended Xenos plugin and XEX, produces
shader pipelines and 46 guest-output presents, captures a visibly non-flat
Saw II frame, and submits audio. It passes the former `0x8231ED50` failure and
then terminates at the new unregistered guest target `0x82275238`. The exact
0x18-byte hint is now in the manifest, but its post-change build/runtime result
is pending. The failure and visible-frame evidence were captured in local runtime logs and
frame captures. Those generated diagnostics are intentionally excluded from the
public repository.

The synthetic-controller run proves SDL host enumeration but contains no
`XamInputGetCapabilities` or `XamInputGetState` call. It is therefore not
evidence of a guest-visible controller state.
