# FlashCopy Implementation Comparison (Cinder, CSI, PVE Plugin)

Scope: FlashCopy-based paths only. This excludes addsnapshot/virtual snapshot
function and any host-side copy logic.

Legend:
- <src> = source volume name
- <snap> = snapshot volume name
- <tgt> = target volume name (new volume)
- <id> = FlashCopy mapping id

## Snapshot Create (copyrate 0)

| Implementation | Steps (CLI/REST) |
| --- | --- |
| Cinder (storwize_svc) | 1) `svcinfo lsvdisk -bytes <src>`<br>2) `svctask mkvdisk -name <snap> -mdiskgrp <pool> -iogrp <iogrp> -size <bytes> -unit b ...`<br>3) `svctask mkfcmap -source <src> -target <snap> -copyrate 0 [-cleanrate <clean_rate>]`<br>4) `svctask prestartfcmap <id>`<br>5) `svctask startfcmap <id>` |
| CSI (ibm-block-csi-driver) | 1) `svcinfo lsvdisk -bytes <src>`<br>2) `svctask mkvolume -name <snap> -pool <pool> -iogrp <iogrp> -size <bytes> -unit b ...`<br>3) `svctask mkfcmap -source <src> -target <snap> -copyrate 0`<br>4) `svcinfo lsvdisk <snap>` (read `FC_id`)<br>5) `svctask startfcmap -prep <id>` |
| PVE plugin (this repo) | 1) `POST /rest/lsvdisk/<src> {bytes:true}`<br>2) `POST /rest/mkvolume {name:<snap>,pool:<pool>,size:<bytes>,unit:"b",thin:true}`<br>3) `POST /rest/lsvdisk/<snap>` (wait for exist)<br>4) `POST /rest/mkfcmap {source:<src>,target:<snap>,copyrate:0}`<br>5) `POST /rest/prestartfcmap/<id>`<br>6) `POST /rest/startfcmap/<id>`<br>7) `POST /rest/lsfcmap/<id>` (wait for `copying` or `idle_or_copied`) |

## Snapshot Delete

| Implementation | Steps (CLI/REST) |
| --- | --- |
| Cinder (storwize_svc) | 1) `svcinfo lsvdiskfcmappings <snap>` and `svcinfo lsfcmap <id>`<br>2) If snapshot is target and `copy_rate=0`: `svctask stopfcmap <id>` -> `svctask rmfcmap <id>`<br>3) If snapshot is source and `copy_rate=0`: `svctask chfcmap -copyrate 50 -autodelete on <id>` (wait for cleanup)<br>4) `svctask rmvdisk <snap>` |
| CSI (ibm-block-csi-driver) | 1) `svcinfo lsfcmap -filtervalue target_vdisk_name=<snap>`<br>2) `svctask stopfcmap <id>`<br>3) `svctask rmfcmap -force <id>`<br>4) `svctask rmvolume <snap>` |
| PVE plugin (this repo) | 1) `POST /rest/lsfcmap` (find mappings where source/target is `<snap>`)<br>2) `POST /rest/stopfcmap/<id>` -> `POST /rest/rmfcmap/<id> {force:true}` (wait for removal)<br>3) `POST /rest/rmvdiskhostmap/<snap> {host:<hostname>}`<br>4) `POST /rest/rmvdisk/<snap>` (retries on `CMMVC5840E`) |

## Snapshot Rollback / Revert

| Implementation | Steps (CLI/REST) |
| --- | --- |
| Cinder (storwize_svc) | 0) Pretreatment: `svcinfo lsvdiskfcmappings <vol>` + `svcinfo lsfcmap <id>`; stop active clone maps if needed<br>1) `svctask mkfcmap -source <snap> -target <vol> -copyrate <flashcopy_rate> -autodelete [-cleanrate <clean_rate>]`<br>2) `svctask prestartfcmap -restore <id>`<br>3) `svctask startfcmap -restore <id>` |
| CSI (ibm-block-csi-driver) | Not implemented (no FlashCopy revert in CSI driver) |
| PVE plugin (this repo) | 1) `POST /rest/lsfcmap` (collect mappings where source is `<vol>`)<br>2) `POST /rest/stopfcmap/<id>` -> `POST /rest/rmfcmap/<id> {force:true}` for all source mappings<br>3) `POST /rest/mkfcmap {source:<snap>,target:<vol>,copyrate:150,cleanrate:150}`<br>4) `POST /rest/prestartfcmap/<id>` -> `POST /rest/startfcmap/<id>`<br>5) `POST /rest/lsfcmap/<id>` (wait for `idle_or_copied`)<br>6) `POST /rest/rmfcmap/<id> {force:true}`<br>7) Recreate snapshot star: `POST /rest/mkfcmap {source:<vol>,target:<snapX>,copyrate:0}` + `prestart` + `start` for each snapshot target |

### Cinder Rollback (expanded)

1) Validate sizes: snapshot size must equal volume size (no CLI; enforced in driver).
2) If replication is enabled, stop relationships first (commands depend on RC vs RCCG):
   - RC relationship: `svctask stoprcrelationship <rcrel> -access no`
   - RCCG: `svctask stoprccg <rccg> -access no`
3) Pretreatment to ensure no conflicting FlashCopy targets:
   - `svcinfo lsvdiskfcmappings <vol>`
   - For each mapping id: `svcinfo lsfcmap <id>`
   - If `target_vdisk_name == <vol>` and `copy_rate != 0`:
     - If `status in (copying, prepared)` and `progress < 100`: abort revert.
     - If `progress == 100`: `svctask stopfcmap <id>` (split completed clone map).
4) Create and run restore FlashCopy (full copy, autodelete):
   - `svctask mkfcmap -source <snap> -target <vol> -copyrate <flashcopy_rate> -autodelete [-cleanrate <clean_rate>]`
   - `svctask prestartfcmap -restore <id>` (driver waits for `status=prepared`)
   - `svctask startfcmap -restore <id>`
5) If replication was stopped, start it back:
   - RC relationship: `svctask startrcrelationship <rcrel>`
   - RCCG: `svctask startrccg <rccg>`
6) Note on `-restore` behavior (from SVC CLI docs):
   - `-restore` forces prepare even if the target volume is an active source in another mapping.
   - If the target is not a source in another mapping, `-restore` is ignored.
   - This is why Cinder does not remove `copy_rate=0` snapshot mappings during revert.

## Create Volume From Snapshot / Full Clone

| Implementation | Steps (CLI/REST) |
| --- | --- |
| Cinder (storwize_svc) | 1) `svcinfo lsvdisk -bytes <src>` (snapshot or source volume)<br>2) `svctask mkvdisk -name <tgt> -mdiskgrp <pool> -iogrp <iogrp> -size <bytes> -unit b ...`<br>3) `svctask mkfcmap -source <src> -target <tgt> -copyrate <flashcopy_rate> -autodelete [-cleanrate <clean_rate>]`<br>4) `svctask prestartfcmap <id>`<br>5) `svctask startfcmap <id>`<br>6) Optional: `svctask expandvdisksize -size <delta> -unit gb <tgt>` if target size larger |
| CSI (ibm-block-csi-driver) | 1) `svctask mkvolume -name <tgt> -pool <pool> -iogrp <iogrp> -size <bytes> -unit b ...`<br>2) `svctask mkfcmap -source <src> -target <tgt>` (copyrate not set; uses system default)<br>3) `svcinfo lsvdisk <tgt>` (read `FC_id`)<br>4) `svctask startfcmap -prep <id>` |
| PVE plugin (this repo) | 1) `POST /rest/lsvdisk/<src> {bytes:true}`<br>2) `POST /rest/mkvolume {name:<tgt>,pool:<pool>,size:<bytes>,unit:"b",thin:true}`<br>3) `POST /rest/mkfcmap {source:<src>,target:<tgt>,copyrate:100,autodelete:true}`<br>4) `POST /rest/prestartfcmap/<id>`<br>5) `POST /rest/startfcmap/<id>` |

## Linked Clone (copyrate 0, persistent)

| Implementation | Steps (CLI/REST) |
| --- | --- |
| Cinder (storwize_svc) | Not implemented (uses full copy for clones) |
| CSI (ibm-block-csi-driver) | Not implemented (uses full copy for clones) |
| PVE plugin (this repo) | 1) `POST /rest/mkvolume {name:<tgt>,pool:<pool>,size:<bytes>,unit:"b",thin:true}`<br>2) `POST /rest/mkfcmap {source:<src>,target:<tgt>,copyrate:0,autodelete:false}`<br>3) Mapping is not started; remains as persistent COW link |

## Code References

- Cinder (SVC): `/Users/n.kozlov/Documents/Projects/cinder/cinder/volume/drivers/ibm/storwize_svc/storwize_svc_common.py`
- CSI (SVC): `/Users/n.kozlov/Documents/Projects/ibm-block-csi-driver/controllers/array_action/array_mediator_svc.py`
- PVE plugin: `PVE/Storage/Custom/IBMFlashSystem/Snapshot.pm`, `PVE/Storage/Custom/IBMFlashSystem/Volume.pm`, `PVE/Storage/Custom/IBMFlashSystem/FCMap.pm`
