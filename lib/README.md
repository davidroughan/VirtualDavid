# lib/ — optional Java jars

This folder is only needed for **Outlook binary `.msg`** support in the email
reader. Plain **`.eml` (MIME)** files need nothing here — they're parsed in pure
ColdFusion by [`cfcs/EmailReader.cfc`](../cfcs/EmailReader.cfc).

## When you need it

`EmailReader` detects an Outlook `.msg` by its OLE2 magic bytes and parses it via
Apache POI's HSMF module (`org.apache.poi.hsmf.MAPIMessage`). POI's core ships
with ColdFusion/Lucee for spreadsheet support, but **HSMF lives in
`poi-scratchpad.jar`, which is usually not on the classpath**. If it's missing,
`.msg` ingestion fails with an actionable message (and `.eml` keeps working).

## Drop-in

1. Download a matching pair from Maven Central (same version, e.g. 5.x):
   - `poi-<ver>.jar`
   - `poi-scratchpad-<ver>.jar`
   - (and their transitive deps if your engine doesn't already supply them:
     `commons-collections4`, `commons-io`, `log4j-api`)
2. Put the jars in this folder.
3. Make the engine load them:
   - **Lucee** — add this folder to *Server Admin → Services → Java → Library
     directory*, or set `javaSettings` on the app:
     ```cfml
     // Application.cfc
     this.javaSettings = { loadPaths = [ expandPath("/vd/lib") ], reloadOnChange = false };
     ```
   - **Adobe ColdFusion** — copy the jars into `cfusion/lib/` and restart, or add
     this folder under *CF Admin → Server Settings → Java and JVM → ColdFusion
     Class Path* and restart.
4. Re-test by previewing a `.msg` in `admin/emails.cfm`.

If you only ever deal with `.eml` exports, you can ignore this folder entirely.
