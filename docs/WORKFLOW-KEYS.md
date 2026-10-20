# Fuego workflows on Stream Deck

Stream Deck Module and Elgato companion 0.3.0 use generic shared actions. NeroNook
0.28.0 provides compact run display; Fuego Agent 0.4.0 provides independent job
handoff and waiting. None imports or bundles another plugin's implementation.
Older hosts still support ordinary actions; detailed workflow step metadata needs
0.28.0. Only one workflow runs at a time in the current host.

## Set up two keys

1. Create or select a saved manual workflow in Automations. A Fuego workflow can
   prepare a task, pass its returned request ID to Wait for a Fuego job to finish,
   then pass that exact ID to Read confirmed final status. Choose actions from
   the live catalog; don't paste IDs from another run.
2. Allow Automations the specific Fuego actions it uses, and allow Stream Deck
   only that workflow in NeroNook Settings → Modules → Actions and connections.
   Updating a package or editing a graph requires renewed exact grants/mapping.
3. In Elgato, drag NeroNook → Run Action and Stop Run to empty keys. In the Nook
   Deck studio, select each lit key, choose the same permitted workflow and Save
   mapping. Or use the Elgato inspector. Labels such as Fuego and Stop Fuego
   distinguish them; compact key titles display up to 12 characters per label. A Stop mapping takes no arguments.
4. Press Run. Review the saved workflow and its changing steps in the Nook.
   Fuego still shows the exact task, agent, computer, workspace and standing
   instructions before its own Send to Fuego. No job starts from approval of a
   draft alone. Read-only steps don't need another review.
5. Press the paired Stop to request cancellation of this deck's exact active
   run. It shows Stopping until a bound terminal outcome arrives. A confirmed
   stop displays Stopped; unavailable confirmation displays Unknown.
   Completed effects cannot be undone. Stop with no active run sends nothing.

## What the keys show

Run and Stop keys show Review, Running, Stopping, Done, Stopped, Failed
or Unknown. Review opens in the Nook; Unknown means inspect the original outcome. The ring/count is completed workflow steps, such as 2/4, not a
made-up percentage for remote work. Elapsed time freezes when terminal. Detailed
provider stages and result previews stay in the Nook; Fuego owns the durable full
answer. Key artwork is original vector drawing, with state colors and symbols.

One active run per action is owned by this companion. Repeated Run presses don't
create another job; repeated Stop presses don't repeat cancellation. Changing
pages or removing the visible key does not cancel the run. A newly visible Stop
key mapped to the same action can still stop it. Losing the core connection or
restarting the companion marks the outcome unknown; it does not replay or take
ownership of an old request. Inspect that original workflow and Fuego handoff.

## Verified installation on 14 October 2026

Stream Deck+ → Default Profile → page 3, top row third key is Fuego; fourth is
Stop Fuego. Both map to Fuego — wait for completion. The earlier Connected key
on the second row remains. Two synthetic, text-only Ember jobs exercised actual
native launch, 2/4 progress, page changes, confirmed remote Stop and later 4/4
completion with a result. The isolated signed bridge additionally covers
repeated presses, late updates, disconnection and restart without replay.
The owner confirmed the physical Run key opens the review. Native readback
showed Prepare a Fuego task for review waiting for approval, and the saved
handoff count remained 15: no new remote job was sent. The later physical
Run/Stop pair cancelled an active review in three seconds; the owner and matching
SDK receipt agree. That review sent no job. Physical Stop during remote execution
remains a separate acceptance check. Normal mappings are restored; other profiles
were not rewritten. [Physical evidence](../reports/physical-stop-2026-10-14/README.md).

[Full evidence](../reports/workflow-keys-2026-10-14/README.md).
