<cfcomponent displayname="EmailReader" output="false"
    hint="Reads a saved email file (.eml MIME, or Outlook binary .msg) into a normalised struct: headers, the best plain-text body, the unrolled reply/forward chain (split by Outlook's From/Sent/Subject blocks), and attachment metadata. Pure parsing - no DB, no embeddings, no LLM. The 'see comments below' inline-reply separation is left to EmailIngestor (it needs the LLM).">

    <cffunction name="init" access="public" returntype="EmailReader" output="false">
        <cfreturn this>
    </cffunction>

    <!--- ====================================================================
          Public entry point
          ==================================================================== --->

    <!---
        readFile
        --------
        Detects the format from the file's leading bytes (OLE compound-file magic
        => .msg, otherwise treat as MIME .eml) and dispatches. Returns:

            success      - boolean
            error        - populated on failure
            format       - "eml" | "msg"
            headers      - { from, to, subject, date, messageId }
            plainText    - decoded body of the OUTERMOST message (raw, uncleaned)
            cleanText    - plainText with signatures / footers / cid refs stripped
            chain        - array of { from, sent, to, subject, body, isDavid },
                           outermost first, innermost (the original) last
            original     - the innermost chain entry (where, for a "see comments
                           below" reply, the dev's questions and David's inline
                           answers are interleaved). Empty struct if no chain.
            attachments  - array of { filename, contentType, contentId, disposition, bytes }
    --->
    <cffunction name="readFile" access="public" returntype="struct" output="false">
        <cfargument name="path"       type="string" required="true">
        <cfargument name="davidMatch" type="string" required="false" default="David Roughan,DavidR@,droughan@">

        <cfset var out = {
            "success" = false, "error" = "", "format" = "",
            "headers" = { "from" = "", "to" = "", "subject" = "", "date" = "", "messageId" = "" },
            "plainText" = "", "cleanText" = "", "chain" = [], "original" = {}, "attachments" = []
        }>
        <cfset var bytes = "">
        <cfset var magic = "">
        <cfset var raw = "">

        <cftry>
            <cfif NOT fileExists(arguments.path)>
                <cfset out.error = "File not found: " & arguments.path>
                <cfreturn out>
            </cfif>

            <!--- Sniff the first 8 bytes. OLE2 / CFBF (what .msg is) always starts
                  D0 CF 11 E0 A1 B1 1A E1. Anything else we treat as RFC822 text. --->
            <cfset bytes = fileReadBinary(arguments.path)>
            <cfset magic = lcase(left(binaryEncode(bytes, "hex"), 16))>

            <cfif magic eq "d0cf11e0a1b11ae1">
                <cfset out.format = "msg">
                <cfset out = parseMsg(arguments.path, out, arguments.davidMatch)>
            <cfelse>
                <cfset out.format = "eml">
                <!--- bytes -> text once; the body's base64/QP is ASCII anyway. --->
                <cfset raw = toString(bytes, "utf-8")>
                <cfset out = parseEml(raw, out, arguments.davidMatch)>
            </cfif>

            <cfcatch type="any">
                <cfset out.success = false>
                <cfset out.error = "readFile failed: " & cfcatch.message & (len(cfcatch.detail) ? " | " & cfcatch.detail : "")>
            </cfcatch>
        </cftry>

        <cfreturn out>
    </cffunction>

    <!--- ====================================================================
          .eml (MIME) parsing
          ==================================================================== --->

    <cffunction name="parseEml" access="private" returntype="struct" output="false">
        <cfargument name="raw"        type="string" required="true">
        <cfargument name="out"        type="struct" required="true">
        <cfargument name="davidMatch" type="string" required="true">

        <cfset var o = arguments.out>
        <cfset var split = splitHeaderBody(arguments.raw)>
        <cfset var hdrs = parseHeaders(split.head)>
        <cfset var entity = { "headers" = hdrs, "body" = split.body }>
        <cfset var leaves = []>
        <cfset var leaf = "">
        <cfset var primary = "">

        <!--- top-level envelope headers --->
        <cfset o.headers.from      = headerValue(hdrs, "from")>
        <cfset o.headers.to        = headerValue(hdrs, "to")>
        <cfset o.headers.subject   = headerValue(hdrs, "subject")>
        <cfset o.headers.date      = headerValue(hdrs, "date")>
        <cfset o.headers.messageId = headerValue(hdrs, "message-id")>

        <!--- recursively flatten the MIME tree into leaf parts --->
        <cfset leaves = collectLeaves(entity)>

        <!--- choose the body: first non-attachment text/plain, else first text/html
              (stripped to text). Collect attachments along the way. --->
        <cfloop array="#leaves#" index="leaf">
            <cfif leaf.isAttachment>
                <cfset arrayAppend(o.attachments, {
                    "filename"    = leaf.filename,
                    "contentType" = leaf.contentType,
                    "contentId"   = leaf.contentId,
                    "disposition" = leaf.disposition,
                    "bytes"       = leaf.byteLen
                })>
            <cfelseif NOT len(primary) AND leaf.contentType eq "text/plain">
                <cfset primary = leaf.text>
            </cfif>
        </cfloop>

        <cfif NOT len(primary)>
            <!--- no usable text/plain - fall back to the first text/html part --->
            <cfloop array="#leaves#" index="leaf">
                <cfif NOT leaf.isAttachment AND leaf.contentType eq "text/html">
                    <cfset primary = htmlToText(leaf.text)>
                    <cfbreak>
                </cfif>
            </cfloop>
        </cfif>

        <cfset o.plainText = primary>
        <cfset finishCommon(o, arguments.davidMatch)>
        <cfset o.success = true>
        <cfreturn o>
    </cffunction>

    <!--- Recursively flatten a MIME entity into an array of leaf parts.
          multipart/* => recurse into each child and concatenate; anything else
          => a single decoded leaf. Returns (rather than mutates an arg) so it
          behaves the same on Adobe CF, which passes arrays by value. --->
    <cffunction name="collectLeaves" access="private" returntype="array" output="false">
        <cfargument name="entity" type="struct" required="true">

        <cfset var leaves = []>
        <cfset var ct = headerValue(arguments.entity.headers, "content-type")>
        <cfset var ctLower = lcase(ct)>
        <cfset var boundary = paramValue(ct, "boundary")>
        <cfset var parts = "">
        <cfset var p = "">
        <cfset var childSplit = "">
        <cfset var childHeaders = "">
        <cfset var childLeaves = "">
        <cfset var cl = "">
        <cfset var enc = lcase(headerValue(arguments.entity.headers, "content-transfer-encoding"))>
        <cfset var disp = lcase(headerValue(arguments.entity.headers, "content-disposition"))>
        <cfset var mediaType = trim(listFirst(ctLower, ";"))>
        <cfset var filename = paramValue(disp, "filename")>
        <cfset var decoded = "">

        <cfif left(mediaType, len("multipart/")) eq "multipart/" AND len(boundary)>
            <cfset parts = splitMultipart(arguments.entity.body, boundary)>
            <cfloop array="#parts#" index="p">
                <cfset childSplit = splitHeaderBody(p)>
                <cfset childHeaders = parseHeaders(childSplit.head)>
                <cfset childLeaves = collectLeaves({ "headers" = childHeaders, "body" = childSplit.body })>
                <cfloop array="#childLeaves#" index="cl">
                    <cfset arrayAppend(leaves, cl)>
                </cfloop>
            </cfloop>
            <cfreturn leaves>
        </cfif>

        <!--- leaf part --->
        <cfif NOT len(filename)>
            <cfset filename = paramValue(ct, "name")>
        </cfif>

        <cfif (left(disp, len("attachment")) eq "attachment")
              OR (left(mediaType, 6) eq "image/")
              OR (left(disp, len("inline")) eq "inline" AND len(filename))>
            <!--- attachment: record metadata, don't materialise the bytes as text --->
            <cfset arrayAppend(leaves, {
                "isAttachment" = true,
                "contentType"  = mediaType,
                "filename"     = filename,
                "contentId"    = trim(reReplace(headerValue(arguments.entity.headers, "content-id"), "[<>]", "", "all")),
                "disposition"  = len(disp) ? trim(listFirst(disp, ";")) : "inline",
                "byteLen"      = estimateDecodedSize(arguments.entity.body, enc),
                "text"         = ""
            })>
        <cfelse>
            <cfset decoded = decodeBody(arguments.entity.body, enc, charsetOf(ct))>
            <cfset arrayAppend(leaves, {
                "isAttachment" = false,
                "contentType"  = mediaType,
                "filename"     = "",
                "contentId"    = "",
                "disposition"  = "inline",
                "byteLen"      = len(decoded),
                "text"         = decoded
            })>
        </cfif>
        <cfreturn leaves>
    </cffunction>

    <!--- ====================================================================
          .msg (Outlook binary) parsing - via Apache POI HSMF
          ==================================================================== --->

    <!---
        Outlook .msg is an OLE2 compound file; parsing it in pure CFML is
        impractical, so we lean on Apache POI's HSMF module (org.apache.poi.hsmf).
        POI's core (poi.jar) ships with ColdFusion/Lucee for spreadsheet support,
        but HSMF lives in poi-scratchpad.jar which is usually NOT bundled. If the
        class can't be loaded we fail with an actionable message rather than a
        stack trace - see lib/README for the drop-in instructions.

        POI hands us the whole reply chain as one plain-text body, just like the
        .eml text/plain part, so everything downstream (cleaning, chain split,
        LLM segmentation) is shared.
    --->
    <cffunction name="parseMsg" access="private" returntype="struct" output="false">
        <cfargument name="path"       type="string" required="true">
        <cfargument name="out"        type="struct" required="true">
        <cfargument name="davidMatch" type="string" required="true">

        <cfset var o = arguments.out>
        <cfset var msg = "">
        <cfset var body = "">

        <cftry>
            <cfset msg = createObject("java", "org.apache.poi.hsmf.MAPIMessage").init(javaCast("string", arguments.path))>
            <cfcatch type="any">
                <cfset o.error = "Outlook .msg support needs Apache POI's HSMF module on the classpath "
                    & "(org.apache.poi.hsmf.MAPIMessage could not be loaded). Drop poi.jar + "
                    & "poi-scratchpad.jar into the app's lib/ folder - see lib/README.md. "
                    & "Underlying error: " & cfcatch.message>
                <cfreturn o>
            </cfcatch>
        </cftry>

        <!--- subject / from --->
        <cftry><cfset o.headers.subject = toString(msg.getSubject())><cfcatch type="any"></cfcatch></cftry>
        <cftry><cfset o.headers.from    = toString(msg.getDisplayFrom())><cfcatch type="any"></cfcatch></cftry>
        <cftry><cfset o.headers.to      = toString(msg.getDisplayTo())><cfcatch type="any"></cfcatch></cftry>

        <!--- body: prefer plain text; fall back to HTML, then RTF-stripped. POI
              throws ChunkNotFoundException when a given body form is absent. --->
        <cftry>
            <cfset body = toString(msg.getTextBody())>
            <cfcatch type="any">
                <cftry>
                    <cfset body = htmlToText(toString(msg.getHtmlBody()))>
                    <cfcatch type="any">
                        <cfset body = "">
                    </cfcatch>
                </cftry>
            </cfcatch>
        </cftry>

        <cfif NOT len(trim(body))>
            <cfset o.error = "Parsed the .msg but found no readable text/HTML body.">
            <cfreturn o>
        </cfif>

        <cfset o.plainText = body>
        <cfset finishCommon(o, arguments.davidMatch)>
        <cfset o.success = true>
        <cfreturn o>
    </cffunction>

    <!--- ====================================================================
          Shared post-processing: clean + split the reply/forward chain
          ==================================================================== --->

    <cffunction name="finishCommon" access="private" returntype="void" output="false">
        <cfargument name="o"          type="struct" required="true">
        <cfargument name="davidMatch" type="string" required="true">

        <cfset arguments.o.cleanText = cleanBody(arguments.o.plainText)>
        <cfset arguments.o.chain     = splitChain(arguments.o.cleanText, arguments.o.headers, arguments.davidMatch)>
        <cfif arrayLen(arguments.o.chain)>
            <cfset arguments.o.original = arguments.o.chain[arrayLen(arguments.o.chain)]>
        </cfif>
    </cffunction>

    <!---
        splitChain
        ----------
        Outlook (and most clients) quote a forwarded/replied message by inserting
        a header block on its own lines:

            From: David Roughan <DavidR@3rdmill.com.au>
            Sent: Monday, June 1, 2026 4:22:55 pm
            To: Tim Salvador <tims@3rdmill.com.au>
            Subject: RE: Questions regarding the Lucinda BAU tickets

        There are no '>' quote markers. We split the cleaned text wherever such a
        block appears: each block starts a new (deeper) message in the chain, and
        the text after it (up to the next block) is that message's body. The text
        before the FIRST block belongs to the outermost message, whose metadata we
        seed from the envelope headers.
    --->
    <cffunction name="splitChain" access="private" returntype="array" output="false">
        <cfargument name="text"       type="string" required="true">
        <cfargument name="headers"    type="struct" required="true">
        <cfargument name="davidMatch" type="string" required="true">

        <cfset var lines = listToArray(arguments.text, chr(10), true)>
        <cfset var n = arrayLen(lines)>
        <cfset var i = 1>
        <cfset var chain = []>
        <cfset var buffer = []>
        <cfset var curMeta = {
            "from"    = arguments.headers.from,
            "sent"    = arguments.headers.date,
            "to"      = arguments.headers.to,
            "subject" = arguments.headers.subject
        }>
        <cfset var blk = "">

        <cfloop condition="i lte n">
            <cfset blk = readHeaderBlock(lines, i, n)>
            <cfif blk.matched>
                <!--- close the message we were accumulating --->
                <cfset arrayAppend(chain, makeChainEntry(curMeta, buffer, arguments.davidMatch))>
                <cfset buffer = []>
                <cfset curMeta = blk.meta>
                <cfset i = blk.nextIndex>
            <cfelse>
                <cfset arrayAppend(buffer, lines[i])>
                <cfset i++>
            </cfif>
        </cfloop>
        <cfset arrayAppend(chain, makeChainEntry(curMeta, buffer, arguments.davidMatch))>

        <cfreturn chain>
    </cffunction>

    <cffunction name="makeChainEntry" access="private" returntype="struct" output="false">
        <cfargument name="meta"       type="struct" required="true">
        <cfargument name="bufferLines" type="array" required="true">
        <cfargument name="davidMatch" type="string" required="true">

        <cfset var who = arguments.meta.from>
        <cfset var token = "">
        <cfset var isDavid = false>
        <cfloop list="#arguments.davidMatch#" index="token">
            <cfif len(trim(token)) AND findNoCase(trim(token), who)>
                <cfset isDavid = true>
                <cfbreak>
            </cfif>
        </cfloop>
        <cfreturn {
            "from"    = arguments.meta.from,
            "sent"    = arguments.meta.sent,
            "to"      = arguments.meta.to,
            "subject" = arguments.meta.subject,
            "body"    = trim(arrayToList(arguments.bufferLines, chr(10))),
            "isDavid" = isDavid
        }>
    </cffunction>

    <!---
        readHeaderBlock
        ---------------
        Does the run of lines starting at `start` look like a quoted-message
        header block? It must begin with a "From:" line carrying an address-ish
        value, and within the next few lines carry a "Sent:"/"Date:" or
        "Subject:" line. If so, consume the consecutive recognised header lines
        and return the parsed meta plus the index of the first body line.
    --->
    <cffunction name="readHeaderBlock" access="private" returntype="struct" output="false">
        <cfargument name="lines" type="array"   required="true">
        <cfargument name="start" type="numeric" required="true">
        <cfargument name="n"     type="numeric" required="true">

        <cfset var first = arguments.lines[arguments.start]>
        <cfset var j = 0>
        <cfset var look = 0>
        <cfset var ln = "">
        <cfset var hasAnchor = false>
        <cfset var meta = { "from" = "", "sent" = "", "to" = "", "subject" = "" }>
        <cfset var key = "">
        <cfset var valv = "">
        <cfset var nope = { "matched" = false, "meta" = meta, "nextIndex" = arguments.start + 1 }>

        <!--- must start with a From: line that actually names someone --->
        <cfif NOT reFindNoCase("^\s*From\s*:\s*\S", first)>
            <cfreturn nope>
        </cfif>

        <!--- confirm a Sent:/Date:/Subject: anchor within the next 5 lines so we
              don't trip on body prose that merely opens with "From:" --->
        <cfset look = min(arguments.start + 5, arguments.n)>
        <cfloop from="#arguments.start#" to="#look#" index="j">
            <cfif reFindNoCase("^\s*(Sent|Date|Subject)\s*:\s*\S", arguments.lines[j])>
                <cfset hasAnchor = true>
                <cfbreak>
            </cfif>
        </cfloop>
        <cfif NOT hasAnchor>
            <cfreturn nope>
        </cfif>

        <!--- consume consecutive recognised header lines --->
        <cfset j = arguments.start>
        <cfloop condition="j lte arguments.n">
            <cfset ln = arguments.lines[j]>
            <cfif reFindNoCase("^\s*(From|Sent|Date|To|Cc|Bcc|Subject|Importance|Reply-To)\s*:", ln)>
                <cfset key = lcase(trim(reReplace(ln, "^\s*([A-Za-z-]+)\s*:.*$", "\1")))>
                <cfset valv = trim(reReplace(ln, "^\s*[A-Za-z-]+\s*:\s*", ""))>
                <cfif key eq "from"><cfset meta.from = valv>
                <cfelseif key eq "sent" OR key eq "date"><cfset meta.sent = valv>
                <cfelseif key eq "to"><cfset meta.to = valv>
                <cfelseif key eq "subject"><cfset meta.subject = valv>
                </cfif>
                <cfset j++>
            <cfelse>
                <cfbreak>
            </cfif>
        </cfloop>

        <cfreturn { "matched" = true, "meta" = meta, "nextIndex" = j }>
    </cffunction>

    <!--- ====================================================================
          Cleaning
          ==================================================================== --->

    <!---
        cleanBody
        ---------
        Strip the noise Outlook + the mail gateway bolt on, so both the human
        preview and the LLM see mostly real content: cid image placeholders,
        "Get Outlook for ..." promos, the Exclaimer "[CLICK HERE ...]" banner, the
        long confidentiality footer, the gateway version tail, and runs of blank
        lines. Signatures (name / title / phone) are only lightly trimmed - the
        LLM is told to ignore residual signature lines, which is safer than an
        aggressive regex that could eat real content.
    --->
    <cffunction name="cleanBody" access="private" returntype="string" output="false">
        <cfargument name="text" type="string" required="true">

        <cfset var t = arguments.text>

        <!--- normalise newlines --->
        <cfset t = replace(t, chr(13) & chr(10), chr(10), "all")>
        <cfset t = replace(t, chr(13), chr(10), "all")>

        <!--- [cid:image001.png@...] inline-image placeholders --->
        <cfset t = reReplace(t, "\[cid:[^\]]*\]", "", "all")>
        <!--- [CLICK HERE ...] Exclaimer marketing banner --->
        <cfset t = reReplace(t, "\[CLICK HERE[^\]]*\]", "", "all")>
        <!--- zero-width / direction marks that Outlook sprinkles in --->
        <cfset t = reReplace(t, "[#chr(8203)##chr(8204)##chr(8205)##chr(8206)##chr(8207)#]", "", "all")>
        <!--- inline <...> hyperlinks after link text: "support@x<mailto:...>" / "<https://...>" --->
        <cfset t = reReplace(t, "<(https?://|mailto:|tel:)[^>]*>", "", "all")>
        <!--- horizontal rule lines of underscores Outlook inserts above headers --->
        <cfset t = reReplace(t, "(?m)^_{3,}\s*$", "", "all")>
        <!--- "Get Outlook for Android/iOS" promo line --->
        <cfset t = reReplaceNoCase(t, "(?m)^\s*Get Outlook for [^\n]*$", "", "all")>
        <!--- gateway version tail e.g. "Ver4440619" on its own line --->
        <cfset t = reReplaceNoCase(t, "(?m)^\s*Ver\d{5,}\s*$", "", "all")>

        <!--- drop the confidentiality boilerplate from its opener to the end --->
        <cfset t = reReplaceNoCase(t, "(?s)The information contained in this email.*$", "", "one")>

        <!--- collapse 3+ blank lines to a single blank line --->
        <cfset t = reReplace(t, "(\n\s*){3,}", chr(10) & chr(10), "all")>

        <cfreturn trim(t)>
    </cffunction>

    <!--- ====================================================================
          MIME primitives
          ==================================================================== --->

    <!--- Split a raw message/part into its header block and body at the first
          blank line (CRLF or LF). --->
    <cffunction name="splitHeaderBody" access="private" returntype="struct" output="false">
        <cfargument name="raw" type="string" required="true">
        <cfset var s = replace(arguments.raw, chr(13) & chr(10), chr(10), "all")>
        <cfset var pos = find(chr(10) & chr(10), s)>
        <cfif pos eq 0>
            <!--- no blank line: treat the whole thing as headers (degenerate) --->
            <cfreturn { "head" = s, "body" = "" }>
        </cfif>
        <cfreturn {
            "head" = left(s, pos - 1),
            "body" = mid(s, pos + 2, len(s) - pos - 1)
        }>
    </cffunction>

    <!--- Parse a header block into an ordered array of { name (lower), value },
          unfolding RFC822 continuation lines (those starting with SP/TAB). --->
    <cffunction name="parseHeaders" access="private" returntype="array" output="false">
        <cfargument name="head" type="string" required="true">
        <cfset var lines = listToArray(replace(arguments.head, chr(13), "", "all"), chr(10), true)>
        <cfset var out = []>
        <cfset var ln = "">
        <cfset var i = 0>
        <cfset var colon = 0>

        <cfloop from="1" to="#arrayLen(lines)#" index="i">
            <cfset ln = lines[i]>
            <cfif (left(ln, 1) eq " " OR left(ln, 1) eq chr(9)) AND arrayLen(out)>
                <!--- folded continuation of the previous header --->
                <cfset out[arrayLen(out)].value = out[arrayLen(out)].value & " " & trim(ln)>
            <cfelse>
                <cfset colon = find(":", ln)>
                <cfif colon gt 0>
                    <cfset arrayAppend(out, {
                        "name"  = lcase(trim(left(ln, colon - 1))),
                        "value" = trim(mid(ln, colon + 1, len(ln) - colon))
                    })>
                </cfif>
            </cfif>
        </cfloop>
        <cfreturn out>
    </cffunction>

    <!--- First value for a header name (case-insensitive) from a parsed array. --->
    <cffunction name="headerValue" access="private" returntype="string" output="false">
        <cfargument name="headers" type="array"  required="true">
        <cfargument name="name"    type="string" required="true">
        <cfset var h = "">
        <cfset var want = lcase(arguments.name)>
        <cfloop array="#arguments.headers#" index="h">
            <cfif h.name eq want><cfreturn h.value></cfif>
        </cfloop>
        <cfreturn "">
    </cffunction>

    <!--- Pull a parameter (e.g. boundary, charset, name, filename) out of a
          structured header value. Handles quoted and unquoted forms. --->
    <cffunction name="paramValue" access="private" returntype="string" output="false">
        <cfargument name="headerValue" type="string" required="true">
        <cfargument name="param"       type="string" required="true">
        <cfset var m = reFindNoCase(arguments.param & "\s*=\s*""([^""]*)""", arguments.headerValue, 1, true)>
        <cfif arrayLen(m.len) ge 2 AND m.len[2] gt 0>
            <cfreturn mid(arguments.headerValue, m.pos[2], m.len[2])>
        </cfif>
        <cfset m = reFindNoCase(arguments.param & "\s*=\s*([^;\s]+)", arguments.headerValue, 1, true)>
        <cfif arrayLen(m.len) ge 2 AND m.len[2] gt 0>
            <cfreturn mid(arguments.headerValue, m.pos[2], m.len[2])>
        </cfif>
        <cfreturn "">
    </cffunction>

    <cffunction name="charsetOf" access="private" returntype="string" output="false">
        <cfargument name="contentType" type="string" required="true">
        <cfset var cs = paramValue(arguments.contentType, "charset")>
        <cfreturn len(cs) ? cs : "utf-8">
    </cffunction>

    <!--- Split a multipart body on its boundary, returning the raw inner parts.
          Done with an explicit scan rather than listToArray so it doesn't depend
          on engine-specific multi-character-delimiter semantics. Preamble (before
          the first boundary) and the closing "--boundary--" epilogue are dropped. --->
    <cffunction name="splitMultipart" access="private" returntype="array" output="false">
        <cfargument name="body"     type="string" required="true">
        <cfargument name="boundary" type="string" required="true">
        <cfset var delim = "--" & arguments.boundary>
        <cfset var s = replace(arguments.body, chr(13) & chr(10), chr(10), "all")>
        <cfset var dl = len(delim)>
        <cfset var out = []>
        <cfset var pos = find(delim, s)>
        <cfset var partStart = 0>
        <cfset var nextPos = 0>
        <cfset var afterDelim = 0>
        <cfset var nl = 0>
        <cfset var seg = "">

        <cfloop condition="pos gt 0">
            <cfset afterDelim = pos + dl>
            <!--- "--boundary--" closing marker: stop here --->
            <cfif mid(s, afterDelim, 2) eq "--"><cfbreak></cfif>
            <!--- body of this part starts after the boundary line's newline --->
            <cfset nl = find(chr(10), s, afterDelim)>
            <cfif nl eq 0><cfbreak></cfif>
            <cfset partStart = nl + 1>
            <cfset nextPos = find(delim, s, partStart)>
            <cfif nextPos eq 0><cfbreak></cfif>
            <!--- exclude the newline that immediately precedes the next boundary --->
            <cfset seg = mid(s, partStart, nextPos - partStart - 1)>
            <cfset arrayAppend(out, seg)>
            <cfset pos = nextPos>
        </cfloop>
        <cfreturn out>
    </cffunction>

    <!--- Decode a leaf body per its Content-Transfer-Encoding into a string. --->
    <cffunction name="decodeBody" access="private" returntype="string" output="false">
        <cfargument name="body"    type="string" required="true">
        <cfargument name="encoding" type="string" required="true">
        <cfargument name="charset" type="string" required="true">
        <cfset var enc = lcase(trim(arguments.encoding))>

        <cfif enc eq "base64">
            <cfreturn b64ToString(arguments.body, arguments.charset)>
        <cfelseif enc eq "quoted-printable">
            <cfreturn qpToString(arguments.body, arguments.charset)>
        </cfif>
        <!--- 7bit / 8bit / binary / none --->
        <cfreturn arguments.body>
    </cffunction>

    <cffunction name="b64ToString" access="private" returntype="string" output="false">
        <cfargument name="b64"     type="string" required="true">
        <cfargument name="charset" type="string" required="true">
        <cfset var clean = reReplace(arguments.b64, "[^A-Za-z0-9+/=]", "", "all")>
        <cfif NOT len(clean)><cfreturn ""></cfif>
        <cftry>
            <cfreturn toString(binaryDecode(clean, "base64"), arguments.charset)>
            <cfcatch type="any">
                <cfreturn toString(binaryDecode(clean, "base64"), "utf-8")>
            </cfcatch>
        </cftry>
    </cffunction>

    <!--- Decode quoted-printable to a string. Soft line breaks (=<eol>) are
          dropped; =XX hex escapes are emitted as raw bytes and the whole byte
          stream is then decoded in the part's charset (so multi-byte UTF-8
          sequences split across several =XX escapes reassemble correctly). --->
    <cffunction name="qpToString" access="private" returntype="string" output="false">
        <cfargument name="qp"      type="string" required="true">
        <cfargument name="charset" type="string" required="true">
        <cfset var s = replace(arguments.qp, chr(13) & chr(10), chr(10), "all")>
        <cfset var baos = createObject("java", "java.io.ByteArrayOutputStream").init()>
        <cfset var i = 1>
        <cfset var L = 0>
        <cfset var ch = "">
        <cfset var hex = "">

        <!--- drop soft line breaks: "=" at end of line --->
        <cfset s = reReplace(s, "=\n", "", "all")>
        <cfset L = len(s)>
        <cfloop condition="i lte L">
            <cfset ch = mid(s, i, 1)>
            <cfif ch eq "=" AND i + 2 le L>
                <cfset hex = mid(s, i + 1, 2)>
                <cfif reFind("^[0-9A-Fa-f]{2}$", hex)>
                    <cfset baos.write(javaCast("int", inputBaseN(hex, 16)))>
                    <cfset i += 3>
                <cfelse>
                    <cfset baos.write(javaCast("int", asc(ch)))>
                    <cfset i++>
                </cfif>
            <cfelse>
                <cfset baos.write(javaCast("int", asc(ch)))>
                <cfset i++>
            </cfif>
        </cfloop>
        <cftry>
            <cfreturn toString(baos.toByteArray(), arguments.charset)>
            <cfcatch type="any">
                <cfreturn toString(baos.toByteArray(), "utf-8")>
            </cfcatch>
        </cftry>
    </cffunction>

    <!--- Rough decoded byte size of an attachment without materialising it:
          base64 expands ~3 bytes per 4 chars; otherwise count the chars. --->
    <cffunction name="estimateDecodedSize" access="private" returntype="numeric" output="false">
        <cfargument name="body"     type="string" required="true">
        <cfargument name="encoding" type="string" required="true">
        <cfset var clean = "">
        <cfif lcase(trim(arguments.encoding)) eq "base64">
            <cfset clean = reReplace(arguments.body, "[^A-Za-z0-9+/=]", "", "all")>
            <cfreturn ceiling(len(clean) * 3 / 4)>
        </cfif>
        <cfreturn len(arguments.body)>
    </cffunction>

    <!--- Minimal HTML -> text: drop script/style, turn block tags into newlines,
          strip remaining tags, decode the common entities, tidy whitespace. --->
    <cffunction name="htmlToText" access="private" returntype="string" output="false">
        <cfargument name="html" type="string" required="true">
        <cfset var t = arguments.html>
        <cfset t = reReplaceNoCase(t, "(?s)<(script|style)[^>]*>.*?</\1>", "", "all")>
        <cfset t = reReplaceNoCase(t, "<br[^>]*>", chr(10), "all")>
        <cfset t = reReplaceNoCase(t, "</(p|div|tr|li|h[1-6]|table)>", chr(10), "all")>
        <cfset t = reReplace(t, "<[^>]+>", "", "all")>
        <cfset t = replace(t, "&nbsp;", " ", "all")>
        <cfset t = replace(t, "&amp;", "&", "all")>
        <cfset t = replace(t, "&lt;", "<", "all")>
        <cfset t = replace(t, "&gt;", ">", "all")>
        <cfset t = replace(t, "&quot;", '"', "all")>
        <cfset t = replace(t, "&##39;", "'", "all")>
        <cfset t = reReplace(t, "&##\d+;", "", "all")>
        <cfset t = reReplace(t, "[ \t]+", " ", "all")>
        <cfset t = reReplace(t, "(\n\s*){3,}", chr(10) & chr(10), "all")>
        <cfreturn trim(t)>
    </cffunction>

</cfcomponent>
